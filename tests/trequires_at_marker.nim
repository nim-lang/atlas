import std/[unittest]
import basic/versions

suite "requires @ parsing":

  test "name without @ for version constraint":
    let req = "mcu_utils@ >= 0.1.0"
    expect ValueError:
      let (name, feats, idx) = extractRequirementName(req)

  test "name without @ for version constraint":
    let req = "mcu_utils >= @0.1.0"
    let (name, feats, idx) = extractRequirementName(req)
    check name == "mcu_utils"
    check feats.len == 0
    var err = false
    expect ValueError:
      let iv = parseVersionInterval(req, idx, err)

  test "name without reqs":
    let req = "mcu_utils"
    let (name, feats, idx) = extractRequirementName(req)
    check name == "mcu_utils"
    check feats.len == 0
    var err = false
    let iv = parseVersionInterval(req, idx, err)
    check not err
    check $iv == "*"

  test "name without @ for #head":
    let req = "mcu_utils@#head"
    expect ValueError:
      let (name, feats, idx) = extractRequirementName(req)

  test "url without trailing @ in name":
    let req = "https://github.com/EmbeddedNim/mcu_utils@ >= 0.2.0"
    expect ValueError:
      let (name, feats, idx) = extractRequirementName(req)

