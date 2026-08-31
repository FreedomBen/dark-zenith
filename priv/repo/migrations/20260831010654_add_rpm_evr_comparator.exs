defmodule DarkZenith.Repo.Migrations.AddRpmEvrComparator do
  use Ecto.Migration

  @moduledoc """
  RPM EVR ordering in PostgreSQL (DESIGN.md: API Contract Details).

  `dark_zenith_rpmvercmp` implements the RPM 6 segment algorithm exactly —
  tilde, caret, numeric-versus-alpha segments, separators, and leading-zero
  behavior — over raw bytes, matching the C implementation's unsigned-char
  comparisons. `dark_zenith_evr_cmp` compares numeric epochs first, then
  version and release. The `dark_zenith_rpm_evr` composite type carries a
  default btree operator class whose support function delegates to the
  six-argument comparator, so `ORDER BY ROW(epoch, version, release)::
  dark_zenith_rpm_evr` sorts with RPM semantics in plain SQL. Changing any of
  this requires a new migration plus the conformance tests.
  """

  def up do
    execute("""
    CREATE FUNCTION dark_zenith_rpmvercmp(a text, b text) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
    DECLARE
      va bytea := convert_to(a, 'UTF8');
      vb bytea := convert_to(b, 'UTF8');
      la integer := octet_length(va);
      lb integer := octet_length(vb);
      i integer := 0;
      j integer := 0;
      si integer;
      sj integer;
      ca integer;
      cb integer;
      isnum boolean;
      seg_a bytea;
      seg_b bytea;
    BEGIN
      IF a = b THEN
        RETURN 0;
      END IF;

      WHILE i < la OR j < lb LOOP
        -- Skip separator bytes: anything that is not ASCII alphanumeric,
        -- '~' (126), or '^' (94).
        WHILE i < la LOOP
          ca := get_byte(va, i);
          EXIT WHEN (ca BETWEEN 48 AND 57) OR (ca BETWEEN 65 AND 90)
            OR (ca BETWEEN 97 AND 122) OR ca = 126 OR ca = 94;
          i := i + 1;
        END LOOP;

        WHILE j < lb LOOP
          cb := get_byte(vb, j);
          EXIT WHEN (cb BETWEEN 48 AND 57) OR (cb BETWEEN 65 AND 90)
            OR (cb BETWEEN 97 AND 122) OR cb = 126 OR cb = 94;
          j := j + 1;
        END LOOP;

        -- Tilde sorts before everything, including the end of the string.
        IF (i < la AND get_byte(va, i) = 126) OR (j < lb AND get_byte(vb, j) = 126) THEN
          IF NOT (i < la AND get_byte(va, i) = 126) THEN
            RETURN 1;
          END IF;
          IF NOT (j < lb AND get_byte(vb, j) = 126) THEN
            RETURN -1;
          END IF;
          i := i + 1;
          j := j + 1;
          CONTINUE;
        END IF;

        -- Caret sorts like tilde except that the string that ends first
        -- (the base version) is the older one.
        IF (i < la AND get_byte(va, i) = 94) OR (j < lb AND get_byte(vb, j) = 94) THEN
          IF i >= la THEN
            RETURN -1;
          END IF;
          IF j >= lb THEN
            RETURN 1;
          END IF;
          IF get_byte(va, i) <> 94 THEN
            RETURN 1;
          END IF;
          IF get_byte(vb, j) <> 94 THEN
            RETURN -1;
          END IF;
          i := i + 1;
          j := j + 1;
          CONTINUE;
        END IF;

        EXIT WHEN i >= la OR j >= lb;

        -- Grab a completely numeric or completely alphabetic segment from
        -- both strings, typed by the first string's leading byte.
        IF get_byte(va, i) BETWEEN 48 AND 57 THEN
          isnum := true;
          si := i;
          WHILE si < la AND get_byte(va, si) BETWEEN 48 AND 57 LOOP
            si := si + 1;
          END LOOP;
          sj := j;
          WHILE sj < lb AND get_byte(vb, sj) BETWEEN 48 AND 57 LOOP
            sj := sj + 1;
          END LOOP;
        ELSE
          isnum := false;
          si := i;
          WHILE si < la AND ((get_byte(va, si) BETWEEN 65 AND 90)
            OR (get_byte(va, si) BETWEEN 97 AND 122)) LOOP
            si := si + 1;
          END LOOP;
          sj := j;
          WHILE sj < lb AND ((get_byte(vb, sj) BETWEEN 65 AND 90)
            OR (get_byte(vb, sj) BETWEEN 97 AND 122)) LOOP
            sj := sj + 1;
          END LOOP;
        END IF;

        -- Mismatched segment types: numeric is always newer than alpha.
        IF sj = j THEN
          IF isnum THEN
            RETURN 1;
          ELSE
            RETURN -1;
          END IF;
        END IF;

        IF isnum THEN
          -- Strip leading zeros; more remaining digits wins.
          WHILE i < si AND get_byte(va, i) = 48 LOOP
            i := i + 1;
          END LOOP;
          WHILE j < sj AND get_byte(vb, j) = 48 LOOP
            j := j + 1;
          END LOOP;
          IF si - i > sj - j THEN
            RETURN 1;
          END IF;
          IF sj - j > si - i THEN
            RETURN -1;
          END IF;
        END IF;

        -- Bytewise comparison matches strcmp over unsigned chars.
        seg_a := substring(va FROM i + 1 FOR si - i);
        seg_b := substring(vb FROM j + 1 FOR sj - j);
        IF seg_a < seg_b THEN
          RETURN -1;
        END IF;
        IF seg_a > seg_b THEN
          RETURN 1;
        END IF;

        i := si;
        j := sj;
      END LOOP;

      IF i >= la AND j >= lb THEN
        RETURN 0;
      END IF;
      IF i >= la THEN
        RETURN -1;
      END IF;
      RETURN 1;
    END
    $$
    """)

    execute("""
    CREATE FUNCTION dark_zenith_evr_cmp(
      e1 bigint, v1 text, r1 text, e2 bigint, v2 text, r2 text
    ) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
    DECLARE
      rc integer;
    BEGIN
      IF e1 < e2 THEN
        RETURN -1;
      ELSIF e1 > e2 THEN
        RETURN 1;
      END IF;
      rc := dark_zenith_rpmvercmp(v1, v2);
      IF rc <> 0 THEN
        RETURN rc;
      END IF;
      RETURN dark_zenith_rpmvercmp(r1, r2);
    END
    $$
    """)

    execute("CREATE TYPE dark_zenith_rpm_evr AS (epoch bigint, version text, release text)")

    execute("""
    CREATE FUNCTION dark_zenith_rpm_evr_cmp(a dark_zenith_rpm_evr, b dark_zenith_rpm_evr)
    RETURNS integer LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
      SELECT dark_zenith_evr_cmp(a.epoch, a.version, a.release, b.epoch, b.version, b.release)
    $$
    """)

    for {name, op} <- [
          {"lt", "< 0"},
          {"le", "<= 0"},
          {"eq", "= 0"},
          {"ge", ">= 0"},
          {"gt", "> 0"},
          {"ne", "<> 0"}
        ] do
      execute("""
      CREATE FUNCTION dark_zenith_rpm_evr_#{name}(a dark_zenith_rpm_evr, b dark_zenith_rpm_evr)
      RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
        SELECT dark_zenith_rpm_evr_cmp(a, b) #{op}
      $$
      """)
    end

    execute("""
    CREATE OPERATOR < (
      LEFTARG = dark_zenith_rpm_evr, RIGHTARG = dark_zenith_rpm_evr,
      FUNCTION = dark_zenith_rpm_evr_lt,
      COMMUTATOR = >, NEGATOR = >=,
      RESTRICT = scalarltsel, JOIN = scalarltjoinsel
    )
    """)

    execute("""
    CREATE OPERATOR <= (
      LEFTARG = dark_zenith_rpm_evr, RIGHTARG = dark_zenith_rpm_evr,
      FUNCTION = dark_zenith_rpm_evr_le,
      COMMUTATOR = >=, NEGATOR = >,
      RESTRICT = scalarlesel, JOIN = scalarlejoinsel
    )
    """)

    execute("""
    CREATE OPERATOR = (
      LEFTARG = dark_zenith_rpm_evr, RIGHTARG = dark_zenith_rpm_evr,
      FUNCTION = dark_zenith_rpm_evr_eq,
      COMMUTATOR = =, NEGATOR = <>,
      RESTRICT = eqsel, JOIN = eqjoinsel,
      MERGES
    )
    """)

    execute("""
    CREATE OPERATOR >= (
      LEFTARG = dark_zenith_rpm_evr, RIGHTARG = dark_zenith_rpm_evr,
      FUNCTION = dark_zenith_rpm_evr_ge,
      COMMUTATOR = <=, NEGATOR = <,
      RESTRICT = scalargesel, JOIN = scalargejoinsel
    )
    """)

    execute("""
    CREATE OPERATOR > (
      LEFTARG = dark_zenith_rpm_evr, RIGHTARG = dark_zenith_rpm_evr,
      FUNCTION = dark_zenith_rpm_evr_gt,
      COMMUTATOR = <, NEGATOR = <=,
      RESTRICT = scalargtsel, JOIN = scalargtjoinsel
    )
    """)

    execute("""
    CREATE OPERATOR <> (
      LEFTARG = dark_zenith_rpm_evr, RIGHTARG = dark_zenith_rpm_evr,
      FUNCTION = dark_zenith_rpm_evr_ne,
      COMMUTATOR = <>, NEGATOR = =,
      RESTRICT = neqsel, JOIN = neqjoinsel
    )
    """)

    execute("""
    CREATE OPERATOR CLASS dark_zenith_rpm_evr_ops
    DEFAULT FOR TYPE dark_zenith_rpm_evr USING btree AS
      OPERATOR 1 <,
      OPERATOR 2 <=,
      OPERATOR 3 =,
      OPERATOR 4 >=,
      OPERATOR 5 >,
      FUNCTION 1 dark_zenith_rpm_evr_cmp(dark_zenith_rpm_evr, dark_zenith_rpm_evr)
    """)
  end

  def down do
    execute("DROP OPERATOR CLASS dark_zenith_rpm_evr_ops USING btree")

    for op <- ["<", "<=", "=", ">=", ">", "<>"] do
      execute("DROP OPERATOR #{op} (dark_zenith_rpm_evr, dark_zenith_rpm_evr)")
    end

    for name <- ["lt", "le", "eq", "ge", "gt", "ne"] do
      execute(
        "DROP FUNCTION dark_zenith_rpm_evr_#{name}(dark_zenith_rpm_evr, dark_zenith_rpm_evr)"
      )
    end

    execute("DROP FUNCTION dark_zenith_rpm_evr_cmp(dark_zenith_rpm_evr, dark_zenith_rpm_evr)")
    execute("DROP TYPE dark_zenith_rpm_evr")
    execute("DROP FUNCTION dark_zenith_evr_cmp(bigint, text, text, bigint, text, text)")
    execute("DROP FUNCTION dark_zenith_rpmvercmp(text, text)")
  end
end
