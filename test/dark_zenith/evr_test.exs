defmodule DarkZenith.EvrTest do
  @moduledoc """
  Conformance tests for the PostgreSQL RPM EVR comparator (DESIGN.md: API
  Contract Details — RPM EVR ordering).

  The corpus below mirrors the upstream librpm rpmvercmp test suite
  (tests/rpmvercmp.at) including tilde and caret semantics; every case was
  differentially validated against RPM 6.0.1's `rpm.vercmp` on 2026-08-30.
  """

  use DarkZenith.DataCase, async: true

  alias DarkZenith.Repo

  # {a, b, expected}
  @corpus [
    {"1.0", "1.0", 0},
    {"1.0", "2.0", -1},
    {"2.0", "1.0", 1},
    {"2.0.1", "2.0.1", 0},
    {"2.0", "2.0.1", -1},
    {"2.0.1", "2.0", 1},
    {"2.0.1a", "2.0.1a", 0},
    {"2.0.1a", "2.0.1", 1},
    {"2.0.1", "2.0.1a", -1},
    {"5.5p1", "5.5p1", 0},
    {"5.5p1", "5.5p2", -1},
    {"5.5p2", "5.5p1", 1},
    {"5.5p10", "5.5p10", 0},
    {"5.5p1", "5.5p10", -1},
    {"5.5p10", "5.5p1", 1},
    {"10xyz", "10.1xyz", -1},
    {"10.1xyz", "10xyz", 1},
    {"xyz10", "xyz10", 0},
    {"xyz10", "xyz10.1", -1},
    {"xyz10.1", "xyz10", 1},
    {"xyz.4", "xyz.4", 0},
    {"xyz.4", "8", -1},
    {"8", "xyz.4", 1},
    {"xyz.4", "2", -1},
    {"2", "xyz.4", 1},
    {"5.5p2", "5.6p1", -1},
    {"5.6p1", "5.5p2", 1},
    {"5.6p1", "6.5p1", -1},
    {"6.5p1", "5.6p1", 1},
    {"6.0.rc1", "6.0", 1},
    {"6.0", "6.0.rc1", -1},
    {"10b2", "10a1", 1},
    {"10a2", "10b2", -1},
    {"1.0aa", "1.0aa", 0},
    {"1.0a", "1.0aa", -1},
    {"1.0aa", "1.0a", 1},
    {"10.0001", "10.0001", 0},
    {"10.0001", "10.1", 0},
    {"10.1", "10.0001", 0},
    {"10.0001", "10.0039", -1},
    {"10.0039", "10.0001", 1},
    {"4.999.9", "5.0", -1},
    {"5.0", "4.999.9", 1},
    {"20101121", "20101121", 0},
    {"20101121", "20101122", -1},
    {"20101122", "20101121", 1},
    {"2_0", "2_0", 0},
    {"2.0", "2_0", 0},
    {"2_0", "2.0", 0},
    {"a", "a", 0},
    {"a+", "a+", 0},
    {"a+", "a_", 0},
    {"a_", "a+", 0},
    {"+a", "+a", 0},
    {"+a", "_a", 0},
    {"_a", "+a", 0},
    {"+_", "+_", 0},
    {"_+", "_+", 0},
    {"_+", "+_", 0},
    {"+", "_", 0},
    {"_", "+", 0},
    {"1.0~rc1", "1.0~rc1", 0},
    {"1.0~rc1", "1.0", -1},
    {"1.0", "1.0~rc1", 1},
    {"1.0~rc1", "1.0~rc2", -1},
    {"1.0~rc2", "1.0~rc1", 1},
    {"1.0~rc1~git123", "1.0~rc1~git123", 0},
    {"1.0~rc1~git123", "1.0~rc1", -1},
    {"1.0~rc1", "1.0~rc1~git123", 1},
    {"1.0^", "1.0^", 0},
    {"1.0^", "1.0", 1},
    {"1.0", "1.0^", -1},
    {"1.0^git1", "1.0^git1", 0},
    {"1.0^git1", "1.0", 1},
    {"1.0", "1.0^git1", -1},
    {"1.0^git1", "1.0^git2", -1},
    {"1.0^git2", "1.0^git1", 1},
    {"1.0^git1", "1.01", -1},
    {"1.01", "1.0^git1", 1},
    {"1.0^20160101", "1.0^20160101", 0},
    {"1.0^20160101", "1.0.1", -1},
    {"1.0.1", "1.0^20160101", 1},
    {"1.0^20160101^git1", "1.0^20160101^git1", 0},
    {"1.0^20160102", "1.0^20160101^git1", 1},
    {"1.0^20160101^git1", "1.0^20160102", -1},
    {"1.0~rc1^git1", "1.0~rc1^git1", 0},
    {"1.0~rc1^git1", "1.0~rc1", 1},
    {"1.0~rc1", "1.0~rc1^git1", -1},
    {"1.0^git1~pre", "1.0^git1~pre", 0},
    {"1.0^git1", "1.0^git1~pre", 1},
    {"1.0^git1~pre", "1.0^git1", -1}
  ]

  defp rpmvercmp(a, b) do
    %{rows: [[result]]} = Repo.query!("SELECT dark_zenith_rpmvercmp($1, $2)", [a, b])
    result
  end

  defp evr_cmp({e1, v1, r1}, {e2, v2, r2}) do
    %{rows: [[result]]} =
      Repo.query!(
        "SELECT dark_zenith_evr_cmp($1, $2, $3, $4, $5, $6)",
        [e1, v1, r1, e2, v2, r2]
      )

    result
  end

  describe "dark_zenith_rpmvercmp/2" do
    test "matches the librpm conformance corpus" do
      failures =
        for {a, b, expected} <- @corpus,
            actual = rpmvercmp(a, b),
            actual != expected,
            do: {a, b, expected, actual}

      assert failures == []
    end

    test "is antisymmetric across the corpus" do
      failures =
        for {a, b, expected} <- @corpus,
            actual = rpmvercmp(b, a),
            actual != -expected,
            do: {b, a, -expected, actual}

      assert failures == []
    end

    test "is declared immutable, strict, and parallel safe" do
      %{rows: rows} =
        Repo.query!("""
        SELECT proname, provolatile, proisstrict, proparallel
        FROM pg_proc
        WHERE proname IN ('dark_zenith_rpmvercmp', 'dark_zenith_evr_cmp')
        ORDER BY proname
        """)

      assert [["dark_zenith_evr_cmp", "i", true, "s"], ["dark_zenith_rpmvercmp", "i", true, "s"]] =
               rows
    end
  end

  describe "dark_zenith_evr_cmp/6" do
    test "numeric epoch dominates version and release" do
      assert evr_cmp({0, "9.9", "9"}, {1, "1.0", "1"}) == -1
      assert evr_cmp({2, "1.0", "1"}, {1, "9.9", "9"}) == 1
      assert evr_cmp({10, "1.0", "1"}, {9, "1.0", "1"}) == 1
    end

    test "version decides when epochs tie; release breaks version ties" do
      assert evr_cmp({0, "1.0", "1"}, {0, "1.1", "1"}) == -1
      assert evr_cmp({0, "1.0", "2"}, {0, "1.0", "10"}) == -1
      assert evr_cmp({0, "1.0", "1.fc43"}, {0, "1.0", "1.fc43"}) == 0
      assert evr_cmp({0, "1.0~rc1", "1"}, {0, "1.0", "1"}) == -1
    end
  end

  describe "dark_zenith_rpm_evr composite type" do
    test "comparison operators use RPM semantics" do
      %{rows: [[lt, gt, eq, le, ge, ne]]} =
        Repo.query!("""
        SELECT
          ROW(0::bigint, '1.0~rc1', '1')::dark_zenith_rpm_evr < ROW(0::bigint, '1.0', '1')::dark_zenith_rpm_evr,
          ROW(0::bigint, '10.0039', '1')::dark_zenith_rpm_evr > ROW(0::bigint, '10.0001', '1')::dark_zenith_rpm_evr,
          ROW(0::bigint, '2.0', '1')::dark_zenith_rpm_evr = ROW(0::bigint, '2_0', '1')::dark_zenith_rpm_evr,
          ROW(0::bigint, '1.0', '1')::dark_zenith_rpm_evr <= ROW(0::bigint, '1.0^git1', '1')::dark_zenith_rpm_evr,
          ROW(1::bigint, '0.1', '1')::dark_zenith_rpm_evr >= ROW(0::bigint, '9.9', '9')::dark_zenith_rpm_evr,
          ROW(0::bigint, '1.0', '1')::dark_zenith_rpm_evr <> ROW(0::bigint, '1.0', '2')::dark_zenith_rpm_evr
        """)

      assert {lt, gt, eq, le, ge, ne} == {true, true, true, true, true, true}
    end

    test "ORDER BY the composite row applies RPM EVR ordering" do
      %{rows: rows} =
        Repo.query!("""
        SELECT v FROM unnest(ARRAY['2.0', '1.0~rc1', '1.0', '1.0^git1', '1.0~rc1~git123', '10.1']) AS v
        ORDER BY ROW(0::bigint, v, '1')::dark_zenith_rpm_evr
        """)

      assert List.flatten(rows) == ["1.0~rc1~git123", "1.0~rc1", "1.0", "1.0^git1", "2.0", "10.1"]
    end

    test "epoch participates in composite ordering ahead of version" do
      %{rows: rows} =
        Repo.query!("""
        SELECT e, v FROM (VALUES (0::bigint, '9.9'), (1::bigint, '1.0'), (0::bigint, '1.0')) AS t(e, v)
        ORDER BY ROW(e, v, '1')::dark_zenith_rpm_evr DESC
        """)

      assert rows == [[1, "1.0"], [0, "9.9"], [0, "1.0"]]
    end
  end
end
