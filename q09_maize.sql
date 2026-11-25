-- ICT371 Q9: Farmer Cooperative Maize Deliveries  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables
CREATE TABLE farmers (
  farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
  delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
  weight_kg    NUMERIC(10,2) NOT NULL,
  unit_rate    NUMERIC(8,2),             -- always set by the trigger
  total_value  NUMERIC(12,2),            -- always set by the trigger
  delivered_on DATE NOT NULL DEFAULT CURRENT_DATE,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(14,2) NOT NULL,
  total_value   NUMERIC(14,2) NOT NULL
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR) RETURNS NUMERIC AS $$
DECLARE v_rate NUMERIC;
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade must not be NULL';
  END IF;
  v_rate := CASE UPPER(p_grade) WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;
  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
  END IF;
  RETURN v_rate;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (d) Trigger: one pricing rule for procedure and direct SQL
CREATE OR REPLACE FUNCTION trg_price_delivery() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
  END IF;
  NEW.grade       := UPPER(NEW.grade);
  NEW.unit_rate   := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_deliveries_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_price_delivery();

INSERT INTO farmers (farmer_number, full_name) VALUES
  ('F001', 'Mwape Chisenga'), ('F002', 'Lweendo Hamoonga'), ('F003', 'Banda Kunda');

-- Six deliveries loaded after the trigger exists (direct SQL; no rate/value supplied)
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
  (1, 'A', 200.00, CURRENT_DATE - 3, TRUE),
  (1, 'B', 150.50, CURRENT_DATE - 2, FALSE),
  (2, 'C', 300.00, CURRENT_DATE - 2, FALSE),
  (2, 'A',  80.25, CURRENT_DATE - 1, TRUE),
  (3, 'B', 120.00, CURRENT_DATE - 1, TRUE),
  (3, 'C', 500.00, CURRENT_DATE - 1, TRUE);    -- farmer 3 has nothing unpaid

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade CHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
    RAISE EXCEPTION 'Unknown farmer_id %', p_farmer_id;
  END IF;
  IF p_grade IS NULL OR UPPER(p_grade) NOT IN ('A','B','C') THEN
    RAISE EXCEPTION 'Invalid grade: %', p_grade;
  END IF;
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Invalid weight: %', p_weight;
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Delivery date must not be NULL';
  END IF;
  -- unit_rate and total_value are left out: the trigger supplies them
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, UPPER(p_grade), p_weight, p_date, FALSE);
END;
$$;

CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE);
-- Tests:
-- CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);   -- unknown farmer
-- CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);    -- bad grade
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on) VALUES (1,'A',-5,CURRENT_DATE); -- rejected

-- (e) View: farmers with no unpaid deliveries show 0
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) Composite index
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
-- Justification: "farmer = ? AND delivered_on BETWEEN ? AND ?" becomes a single index
-- range scan (equality column first, range column second).
ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Refresh procedure (replaces, never adds)
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

SELECT cron.schedule('refresh_purchases_daily', '30 1 * * *',
  $cron$CALL pr_refresh_purchases(CURRENT_DATE - 1)$cron$);

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);   -- rerun: same totals
SELECT * FROM daily_purchases;
