defmodule DarkZenith.Rpm.Tags do
  @moduledoc """
  RPM tag and flag constants used by the parser (DESIGN.md: RPM Parsing).
  Numbers verified against rpm 6.0.1 output for the checked-in fixtures.
  """

  import Bitwise

  ## Region tags
  def region_signature, do: 62
  def region_immutable, do: 63

  ## Signature header tags
  def sig_sha1, do: 269
  def sig_longsize, do: 270
  def sig_longarchivesize, do: 271
  def sig_sha256, do: 273
  def sig_sha3_256, do: 279
  def sig_reserved_v6, do: 999
  def sig_size, do: 1000
  def sig_md5, do: 1004
  def sig_payloadsize, do: 1007

  ## Main header tags
  def i18n_table, do: 100
  def name, do: 1000
  def version, do: 1001
  def release, do: 1002
  def epoch, do: 1003
  def summary, do: 1004
  def description, do: 1005
  def buildtime, do: 1006
  def buildhost, do: 1007
  def size, do: 1009
  def vendor, do: 1011
  def license, do: 1014
  def group, do: 1016
  def url, do: 1020
  def arch, do: 1022
  def old_filenames, do: 1027
  def filemodes, do: 1030
  def fileflags, do: 1037
  def sourcerpm, do: 1044
  def providename, do: 1047
  def requireflags, do: 1048
  def requirename, do: 1049
  def requireversion, do: 1050
  def conflictflags, do: 1053
  def conflictname, do: 1054
  def conflictversion, do: 1055
  def changelogtime, do: 1080
  def changelogname, do: 1081
  def changelogtext, do: 1082
  def obsoletename, do: 1090
  def sourcepackage, do: 1106
  def provideflags, do: 1112
  def provideversion, do: 1113
  def obsoleteflags, do: 1114
  def obsoleteversion, do: 1115
  def dirindexes, do: 1116
  def basenames, do: 1117
  def dirnames, do: 1118
  def longfilesizes, do: 5008
  def longsize, do: 5009
  def filedigestalgo, do: 5011
  def recommendname, do: 5046
  def recommendversion, do: 5047
  def recommendflags, do: 5048
  def suggestname, do: 5049
  def suggestversion, do: 5050
  def suggestflags, do: 5051
  def supplementname, do: 5052
  def supplementversion, do: 5053
  def supplementflags, do: 5054
  def enhancename, do: 5055
  def enhanceversion, do: 5056
  def enhanceflags, do: 5057
  def encoding, do: 5062
  def payloaddigest, do: 5092
  def payloaddigestalgo, do: 5093
  def payloaddigestalt, do: 5097
  def payloadsize_v6, do: 5112
  def payloadsizealt_v6, do: 5113
  def rpmformat, do: 5114
  def sourcenevr, do: 5120

  ## RPMSENSE dependency flags
  def rpmsense_less, do: 0x02
  def rpmsense_greater, do: 0x04
  def rpmsense_equal, do: 0x08
  def rpmsense_comparison_mask, do: 0x0E
  def rpmsense_posttrans, do: 1 <<< 5
  def rpmsense_prereq, do: 1 <<< 6
  def rpmsense_pretrans, do: 1 <<< 7
  def rpmsense_script_pre, do: 1 <<< 9
  def rpmsense_script_post, do: 1 <<< 10
  def rpmsense_rpmlib, do: 1 <<< 24

  @doc "Flags that make a `requires` entry pre-transaction (createrepo_c set)."
  def rpmsense_pre_mask do
    rpmsense_prereq() |||
      rpmsense_script_pre() |||
      rpmsense_script_post() |||
      rpmsense_pretrans() |||
      rpmsense_posttrans()
  end

  ## RPMFILE file flags
  def rpmfile_config, do: 0x01
  def rpmfile_doc, do: 0x02
  def rpmfile_ghost, do: 0x40
  def rpmfile_license, do: 0x80
  def rpmfile_readme, do: 0x100

  ## PGP hash algorithm identifiers (FILEDIGESTALGO / PAYLOADDIGESTALGO)
  def pgphashalgo_sha256, do: 8
  def strong_digest_algos, do: [8, 9, 10, 12, 14]
end
