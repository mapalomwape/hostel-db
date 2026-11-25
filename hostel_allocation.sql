-- Hostel Room Allocation (MySQL 8.0.16+)
-- Only ACTIVE allocations occupy beds; ENDED allocations are history.
DROP DATABASE IF EXISTS hostel;
CREATE DATABASE hostel;
USE hostel;

-- (a) TABLES ---------------------------------------------------------
CREATE TABLE students (
  student_id     INT AUTO_INCREMENT PRIMARY KEY,
  student_number VARCHAR(20)  NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE rooms (
  room_id     INT AUTO_INCREMENT PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT         NOT NULL,
  CONSTRAINT ck_capacity CHECK (capacity > 0)
) ENGINE=InnoDB;

CREATE TABLE allocations (
  allocation_id INT AUTO_INCREMENT PRIMARY KEY,
  student_id    INT         NOT NULL,
  room_id       INT         NOT NULL,
  allocated_on  DATE        NOT NULL,
  released_on   DATE        NULL,
  status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT fk_alloc_student FOREIGN KEY (student_id) REFERENCES students(student_id),
  CONSTRAINT fk_alloc_room    FOREIGN KEY (room_id)    REFERENCES rooms(room_id),
  CONSTRAINT ck_alloc_status  CHECK (status IN ('ACTIVE', 'ENDED')),
  -- ACTIVE requires released_on NULL; ENDED requires a release date
  CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
     OR (status = 'ENDED'  AND released_on IS NOT NULL)),
  CONSTRAINT ck_alloc_dates   CHECK (released_on IS NULL OR released_on >= allocated_on)
) ENGINE=InnoDB;

CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT  NOT NULL,
  occupied_beds INT  NOT NULL,
  free_beds     INT  NOT NULL,
  PRIMARY KEY (snapshot_date, room_id),
  CONSTRAINT fk_snap_room FOREIGN KEY (room_id) REFERENCES rooms(room_id)
) ENGINE=InnoDB;

DELIMITER $$

-- (b) FUNCTION -------------------------------------------------------
CREATE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_capacity INT DEFAULT NULL;
  DECLARE v_active   INT DEFAULT 0;

  SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
  IF v_capacity IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown room';
  END IF;

  -- only ACTIVE rows are counted, so ENDED history never reduces availability
  SELECT COUNT(*) INTO v_active
  FROM allocations
  WHERE room_id = p_room_id AND status = 'ACTIVE';

  RETURN v_capacity - v_active;
END$$

-- Shared rule check, used by both triggers (MySQL has no single
-- "BEFORE INSERT OR UPDATE" trigger, so there is one trigger for each).
CREATE PROCEDURE pr_check_allocation(
  IN p_id INT, IN p_student INT, IN p_room INT, IN p_status VARCHAR(10))
BEGIN
  DECLARE v_student   INT DEFAULT NULL;
  DECLARE v_capacity  INT DEFAULT NULL;
  DECLARE v_other_stu INT DEFAULT 0;
  DECLARE v_other_rm  INT DEFAULT 0;

  IF p_status = 'ACTIVE' THEN
    -- lock student then room (same order every time) so concurrent
    -- direct changes cannot both pass the checks
    SELECT student_id INTO v_student FROM students
    WHERE student_id = p_student FOR UPDATE;
    SELECT capacity INTO v_capacity FROM rooms
    WHERE room_id = p_room FOR UPDATE;

    IF v_student IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
    END IF;
    IF v_capacity IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown room';
    END IF;

    -- one ACTIVE allocation per student (row being changed is excluded)
    SELECT COUNT(*) INTO v_other_stu
    FROM allocations
    WHERE student_id = p_student AND status = 'ACTIVE'
      AND allocation_id <> COALESCE(p_id, 0);
    IF v_other_stu > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
    END IF;

    -- capacity (row being changed is excluded)
    SELECT COUNT(*) INTO v_other_rm
    FROM allocations
    WHERE room_id = p_room AND status = 'ACTIVE'
      AND allocation_id <> COALESCE(p_id, 0);
    IF v_other_rm >= v_capacity THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room is full';
    END IF;
  END IF;
END$$

-- (c) PROCEDURE ------------------------------------------------------
CREATE PROCEDURE pr_allocate_room(
  IN p_student_id INT, IN p_room_id INT, IN p_allocated_on DATE)
BEGIN
  DECLARE v_student INT DEFAULT NULL;
  DECLARE v_room    INT DEFAULT NULL;
  DECLARE v_active  INT DEFAULT 0;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_allocated_on IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Allocation date is required';
  END IF;

  START TRANSACTION;

  SELECT student_id INTO v_student FROM students
  WHERE student_id = p_student_id FOR UPDATE;
  IF v_student IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown student';
  END IF;

  SELECT room_id INTO v_room FROM rooms
  WHERE room_id = p_room_id FOR UPDATE;
  IF v_room IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown room';
  END IF;

  SELECT COUNT(*) INTO v_active
  FROM allocations
  WHERE student_id = p_student_id AND status = 'ACTIVE';
  IF v_active > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student already has an ACTIVE allocation';
  END IF;

  IF fn_free_beds(p_room_id) <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Room is full';
  END IF;

  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');

  COMMIT;
END$$

-- (d) TRIGGERS -------------------------------------------------------
CREATE TRIGGER trg_allocations_bi
BEFORE INSERT ON allocations
FOR EACH ROW
BEGIN
  CALL pr_check_allocation(NULL, NEW.student_id, NEW.room_id, NEW.status);
END$$

CREATE TRIGGER trg_allocations_bu
BEFORE UPDATE ON allocations
FOR EACH ROW
BEGIN
  -- OLD.allocation_id is excluded so a row never counts against itself
  CALL pr_check_allocation(OLD.allocation_id, NEW.student_id, NEW.room_id, NEW.status);
END$$

-- (g) REFRESH PROCEDURE ---------------------------------------------
CREATE PROCEDURE pr_refresh_occupancy()
BEGIN
  -- one row per (date, room); a rerun replaces the values, never duplicates
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE,
         r.room_id,
         COUNT(a.allocation_id),
         r.capacity - COUNT(a.allocation_id)
  FROM rooms r
  LEFT JOIN allocations a
         ON a.room_id = r.room_id AND a.status = 'ACTIVE'
  GROUP BY r.room_id, r.capacity
  ON DUPLICATE KEY UPDATE
    occupied_beds = VALUES(occupied_beds),
    free_beds     = VALUES(free_beds);
END$$

DELIMITER ;

-- (a) SEED DATA ------------------------------------------------------
INSERT INTO students (student_number, full_name) VALUES
  ('202409469', 'Mapalo Mwape'),
  ('202409470', 'Chanda Banda'),
  ('202409471', 'Thandi Phiri'),
  ('202409472', 'Joseph Zulu'),
  ('202409473', 'Esther Tembo'),
  ('202409474', 'Felix Mulenga');     -- student 6 has no allocation

INSERT INTO rooms (room_number, capacity) VALUES
  ('R101', 2),    -- will be full
  ('R102', 3),    -- will be partly occupied
  ('R103', 2);    -- will be empty (history only)

CALL pr_allocate_room(1, 1, '2026-09-01');   -- allocation 1: R101
CALL pr_allocate_room(2, 1, '2026-09-01');   -- allocation 2: R101 now full
CALL pr_allocate_room(3, 2, '2026-09-02');   -- allocation 3: R102
CALL pr_allocate_room(4, 2, '2026-09-02');   -- allocation 4: R102 (2 of 3)
CALL pr_allocate_room(5, 3, '2026-09-03');   -- allocation 5: R103

-- end allocation 5 so R103 is empty but keeps its history
UPDATE allocations
SET status = 'ENDED', released_on = '2026-11-20'
WHERE allocation_id = 5;

-- Tests: each should fail and change nothing
-- CALL pr_allocate_room(6, 1, '2026-11-25');    -- Room is full
-- CALL pr_allocate_room(1, 2, '2026-11-25');    -- student 1 already ACTIVE
-- CALL pr_allocate_room(99, 2, '2026-11-25');   -- unknown student
-- CALL pr_allocate_room(6, 99, '2026-11-25');   -- unknown room
-- Direct SQL is also protected by the triggers:
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (6, 1, '2026-11-25', 'ACTIVE');                       -- Room is full
-- UPDATE allocations SET room_id = 1 WHERE allocation_id = 3;    -- Room is full
-- These should succeed (row being updated is excluded from the count):
-- UPDATE allocations SET allocated_on = '2026-09-02' WHERE allocation_id = 1;
-- CALL pr_allocate_room(5, 3, '2026-11-25');    -- student 5 only has ENDED history

SELECT fn_free_beds(1) AS r101_free;   -- 0  (full)
SELECT fn_free_beds(2) AS r102_free;   -- 1
SELECT fn_free_beds(3) AS r103_free;   -- 2  (ENDED row does not reduce beds)
-- SELECT fn_free_beds(99);            -- Unknown room

SELECT * FROM allocations;

-- (e) VIEW -----------------------------------------------------------
-- The ACTIVE filter is in the JOIN condition (not WHERE), so rooms with
-- no allocations still appear with 0 occupied beds.
CREATE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;
-- R101 2/2/0 (full), R102 3/2/1 (partly), R103 2/0/2 (empty)

-- (f) INDEX ----------------------------------------------------------
-- Both columns are tested for equality: room_id first (also the foreign key
-- column and the leading filter of every per-room query), status second so
-- MySQL jumps straight to a room's ACTIVE rows and can count them from the
-- index alone.
CREATE INDEX idx_alloc_room_status ON allocations (room_id, status);

EXPLAIN SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';
-- Expect: type=ref, key=idx_alloc_room_status, ref=const,const.
-- On tiny tables the optimiser may choose a full scan; to demonstrate use
-- ... FROM allocations FORCE INDEX (idx_alloc_room_status) WHERE ...

-- (g) SCHEDULED JOB --------------------------------------------------
SET GLOBAL event_scheduler = ON;

DROP EVENT IF EXISTS ev_refresh_occupancy;
CREATE EVENT ev_refresh_occupancy
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 23 HOUR + INTERVAL 55 MINUTE)
DO CALL pr_refresh_occupancy();

-- Rerun test: run twice, still exactly one row per date and room
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot;
-- 3 rows for today: R101 2 occupied/0 free, R102 2/1, R103 0/2
