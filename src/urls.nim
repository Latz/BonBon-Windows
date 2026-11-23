## URL helpers: the parts of the browser's URL class that BonBon's code uses.

import std/[uri, strutils]

proc normalized(u: Uri): string =
  var u = u
  u.scheme = u.scheme.toLowerAscii
  u.hostname = u.hostname.toLowerAscii
  if u.hostname.len > 0 and u.path.len == 0:
    u.path = "/"
  result = $u

proc isAbsoluteUrl*(s: string): bool =
  ## True when s parses with a scheme, the way `new URL (s)` doesn't throw.
  try:
    let u = parseUri(s.strip)
    result = u.scheme.len > 0 and u.scheme[0].isAlphaAscii and
      (u.hostname.len > 0 or u.scheme.toLowerAscii notin ["http", "https"])
  except CatchableError:
    result = false

proc resolveUrl*(base, rel: string): string =
  ## `new URL (rel, base).toString ()`; "" when it can't be made.
  try:
    let r = parseUri(rel.strip)
    if r.scheme.len > 0:
      return normalized(r)
    if base.len == 0 or not isAbsoluteUrl(base):
      return ""
    result = normalized(combine(parseUri(base), r))
  except CatchableError:
    result = ""

proc normalizeUrl*(s: string): string =
  ## `new URL (s).toString ()`, or "" when s isn't a URL.
  if isAbsoluteUrl(s): normalized(parseUri(s.strip)) else: ""

proc urlScheme*(s: string): string =
  try: parseUri(s).scheme.toLowerAscii except CatchableError: ""

proc urlOrigin*(s: string): string =
  ## "https://example.com" or "https://example.com:8080"; "" when not a URL.
  if not isAbsoluteUrl(s): return ""
  let u = parseUri(s)
  result = u.scheme.toLowerAscii & "://" & u.hostname.toLowerAscii
  if u.port.len > 0 and not ((u.scheme == "http" and u.port == "80") or (u.scheme == "https" and u.port == "443")):
    result.add ":" & u.port

proc urlHostname*(s: string): string =
  try: parseUri(s).hostname.toLowerAscii except CatchableError: ""

proc urlPath*(s: string): string =
  ## The pathname, "/" when empty, still percent-encoded, as URL.pathname is.
  try:
    result = parseUri(s).path
    if result.len == 0: result = "/"
  except CatchableError:
    result = ""

proc urlHash*(s: string): string =
  let ix = s.find('#')
  if ix == -1: "" else: s[ix .. ^1]

proc urlWithoutHash*(s: string): string =
  let ix = s.find('#')
  if ix == -1: s else: s[0 ..< ix]

proc queryParam*(s, name: string): (bool, string) =
  ## searchParams.get (name): (found, value)
  try:
    for (k, v) in decodeQuery(parseUri(s).query):
      if k == name: return (true, v)
  except CatchableError:
    discard
  (false, "")

proc encodeURIComponent*(s: string): string =
  const keep = {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')'}
  for c in s:
    if c in keep: result.add c
    else: result.add '%' & toHex(ord(c), 2)

proc decodeURIComponent*(s: string): string =
  try: decodeUrl(s, decodePlus = false) except CatchableError: s

proc lastPathName*(s: string): string =
  ## The file name at the end of the URL's path, decoded; "" when the path ends with a slash.
  let p = decodeURIComponent(urlPath(s))
  let ix = p.rfind('/')
  if ix < p.len - 1: p[ix + 1 .. ^1] else: ""
