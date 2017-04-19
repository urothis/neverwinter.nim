import strutils, algorithm, os, streams, json, sequtils, logging, times, tables
export strutils, algorithm, os, streams, json, sequtils, logging, times, tables

import neverwinter.util, neverwinter.resman,
  neverwinter.resref, neverwinter.key,
  neverwinter.resfile, neverwinter.resmemfile, neverwinter.resdir,
  neverwinter.erf, neverwinter.gff, neverwinter.gffjson

# The things we do to cut down import hassle in tools.
# Should clean this up at some point and let the utils deal with it.
export util, resman, resref, key, resfile, resmemfile, resdir, erf, gff, gffjson

import terminal, progressbar, version
export progressbar

addHandler newFileLogger(stderr, fmtStr = "$levelid [$datetime] ")

if isatty(stdout):
  hideCursor()
  system.addQuitProc do () -> void {.noconv.}:
    resetAttributes()
    showCursor()

import docopt as docopt_internal
export docopt_internal

const GlobalUsage = """
  $0 -h | --help
  $0 --version
""".strip

# Options common to ALL utilities
let GlobalOpts = """

Logging:
  --verbose                   Turn on debug logging
  --quiet                     Turn off all logging except errors
  --version                   Show program version and licence info
  --nwn-encoding CHARSET      Sets the nwn encoding [default: """ & getNwnEncoding() & """]
  --other-encoding CHARSET    Sets the "other" file formats encoding, where
                              supported; see docs. Defaults to your current
                              shell/platform charset: [default: """ & getNativeEncoding() & """]  
"""

# Options common to utilities working with a resman.
let ResmanOpts = """

Resman:
  --root ROOT                 Override NWN root (autodetected from BDX)
  --no-keys                   Do not load keys into resman (ignore --keys)
  --keys KEYS                 key files to load (from root:data/)
                              [default: autodetect]
                              Will auto-detect if you are using a 1.69 or 1.8
                              layout.
  --no-ovr                    Do not load ovr/ in resman

  --language LANG             Load language overrides [default: en]

  --erfs ERFS                 Load comma-separated erf files [default: ]
  --dirs DIRS                 Load comma-separated directories [default: ]
""" & GlobalOpts

var Args: Table[string, docopt_internal.Value]

proc DOC*(body: string): Table[string, docopt_internal.Value] =
  let body2 = body.replace("$USAGE", GlobalUsage).
                   replace("$0", getAppFilename().extractFilename()).
                   replace("$OPTRESMAN", ResmanOpts).
                   replace("$OPT", GlobalOpts)

  result = docopt_internal.docopt(body2)
  Args = result

  if Args["--version"]:
    printVersion()
    quit()

  if Args.hasKey("--verbose") and Args["--verbose"]: setLogFilter(lvlDebug)
  elif Args.hasKey("--quiet") and Args["--quiet"]: setLogFilter(lvlError)
  else: setLogFilter(lvlInfo)

  setNwnEncoding($Args["--nwn-encoding"])
  setNativeEncoding($Args["--other-encoding"])

proc findNwnRoot*(): string =
  if Args["--root"]:
    result = $Args["--root"]
  else:
    when defined(macosx):
      const settingsFile = r"~/Library/Application Support/Beamdog Experience/settings.json".expandTilde
    elif defined(linux):
      const settingsFile = r"~/.config/Beamdog Client/settings.json".expandTilde
    elif defined(windows):
      const settingsFile = getHomeDir() / r"AppData\Roaming\Beamdog Client\settings.json"
    else: {.fatal: "Unsupported os for findNwnRoot"}

    let data = readFile(settingsFile)
    let j = data.parseJson
    doAssert(j.hasKey("folders"))
    doAssert(j["folders"].kind == JArray)
    var fo = j["folders"].mapIt(it.str / "00785")
    fo.keepItIf(dirExists(it))
    if fo.len > 0: result = fo[0]

  if result == "" or not dirExists(result): raise newException(ValueError,
    "Could not locate NWN; try --root")
  debug "NWN root: ", result

proc newBasicResMan*(root = findNwnRoot(), language = "", cacheSize = 0): ResMan =
  ## Sets up a resman that defaults to what 1.8 looks like.
  ## Will load an additional language directory, if language is given.

  let resolvedLanguage = if language == "": $Args["--language"] else: language
  let tryOther = resolvedLanguage != "en"
  let otherLangRoot = root / "lang" / resolvedLanguage

  # 1.6
  let legacyLayout = fileExists(root / "chitin.key")
  if legacyLayout: debug("legacy resman layout detected (1.69)")
  else: debug("new resman layout detected (1.8 w/ nwn_base & _loc)")

  doAssert(not legacyLayout or not tryOther,
           "legacy layout (1.69) does not support --language")

  doAssert(not tryOther or dirExists(otherLangRoot), "language " & otherLangRoot &
           " not found")

  # Attempt to auto-detect the resman type we have.
  let actualKeys =
    if $Args["--keys"] == "autodetect":
      # 1.6:
      if legacyLayout: "chitin,xp1,xp2,xp3,xp2patch"
      # 1.8:
      #else: "nwn_base,nwn_base_loc,xp1,xp2,xp3,xp2patch"
      else: "nwn_base,nwn_base_loc"
    else: $Args["--keys"]

  let keys =        actualKeys.split(",").mapIt(it.strip).filterIt(it.len > 0)
  let erfs = ($Args["--erfs"]).split(",").mapIt(it.strip).filterIt(it.len > 0)
  let dirs = ($Args["--dirs"]).split(",").mapIt(it.strip).filterIt(it.len > 0)

  for e in erfs:
    if not fileExists(e): quit("requested --erfs not found: " & e)

  for d in dirs:
    if not dirExists(d): quit("requested --dirs not found: " & d)

  proc loadKey(into: ResMan, key: string) =
    let keyFile = if legacyLayout: key & ".key"
                  else: "data" / key & ".key"
    let fn = if tryOther and fileExists(otherLangRoot / keyFile):
               otherLangRoot / keyFile
             else: root / keyFile

    let ktfn = newFileStream(fn)
    doAssert(ktfn != nil, "key not found or inaccessible: " & fn)

    debug("  key: ", fn)

    let kt = readKeyTable(ktfn, fn) do (fn: string) -> Stream:
      let otherBifFn = otherLangRoot / "data" / fn.extractFilename()
      let bifFn = if tryOther and fileExists(otherBifFn): otherBifFn
                  else: root / fn

      debug("    bif: ", bifFn)
      result = newFileStream(bifFn)
      doAssert(result != nil, "bif not found or inaccessible: " & bifFn)

    into.add(kt)

  debug "Resman (language=", resolvedLanguage, ")"
  result = resman.newResMan(cacheSize)

  if not Args["--no-keys"]:
    for k in keys: #.withProgressBar("load key: "):
      result.loadKey(k)

  for e in erfs: #.withProgressBar("load erf: "):
    let fs = newFileStream(e)
    if fs != nil:
      let erf = fs.readErf(e)
      debug "  ", erf
      result.add(erf)
    else:
      quit("Could not read erf: " & e)

  if not legacyLayout and not Args["--no-ovr"]:
    let c = newResDir(root / "ovr")
    debug "  ", c
    result.add(c)
  if not legacyLayout and tryOther and not Args["--no-ovr"]:
    let c = newResDir(otherLangRoot / "data" / "ovr")
    debug "  ", c
    result.add(c)

  for d in dirs: #.withProgressBar("load resdir: "):
    let c = newResDir(d)
    debug "  ", c
    result.add(c)

proc ensureValidFormat*(format, filename: string,
                       supportedFormats: Table[string, seq[string]]): string =
  result = format
  if result == "autodetect" and filename != "-":
    let ext = splitFile(filename).ext.strip(true, false, {'.'})
    for fmt, exts in supportedFormats:
      if exts.contains(ext):
        result = fmt
        break

  if result == "autodetect":
    quit("Cannot detect file format from filename: " & filename)

  if not supportedFormats.hasKey(result):
    quit("Not a supported file format: " & result)