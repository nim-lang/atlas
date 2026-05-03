#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## HTTP client helpers shared by Atlas network operations.

import std / httpclient
import atlasversion

const AtlasUserAgent* = "atlas/" & AtlasPackageVersion

proc newAtlasHttpClient*(): HttpClient =
  newHttpClient(headers = newHttpHeaders({"User-Agent": AtlasUserAgent}))
