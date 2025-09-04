import std/[unittest]
import basic/versions

suite "requires @ parsing":
  test "name without @ for version constraint":
    let req = "mcu_utils@ >= 0.1.0"
    let (name, feats, idx) = extractRequirementName(req)
    check name == "mcu_utils"
    check feats.len == 0
    var err = false
    let iv = parseVersionInterval(req, idx, err)
    check not err
    check $iv == ">= 0.1.0"

  test "name without @ for #head":
    let req = "mcu_utils@#head"
    let (name, feats, idx) = extractRequirementName(req)
    check name == "mcu_utils"
    check feats.len == 0
    var err = false
    let iv = parseVersionInterval(req, idx, err)
    check not err
    check $iv == "#head"

  test "url without trailing @ in name":
    let req = "https://github.com/EmbeddedNim/mcu_utils@ >= 0.2.0"
    let (name, feats, idx) = extractRequirementName(req)
    check name == "https://github.com/EmbeddedNim/mcu_utils"
    check feats.len == 0
    var err = false
    let iv = parseVersionInterval(req, idx, err)
    check not err
    check $iv == ">= 0.2.0"

