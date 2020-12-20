import hmisc/other/[hcligen, oswrap, colorlogger]
import hmisc/algo/halgorithm
import hmisc/types/colortext
import hmisc/hdebug_misc
import hnimast, hnimast/pprint
import libclang


proc wrapCpp*(
    file, outfile: FsFile,
    codegens: Option[FsDir] = none(FsDir),
    includePaths: seq[FsDir] = @[],
    errorReparseVerbose: bool = false,
    isImportcpp: bool = true,
    globalFlags: seq[string] = @[],
  ) =

  let pconf = baseCppParseConfig.withIt do:
    for fl in includePaths:
      it.globalFlags.add "-I" & fl.getStr()

    for fl in globalFlags:
      it.globalFlags.add fl

  let wconf = baseWrapConfig.withIt do:
    discard

  let wrapped = wrapSingleFile(
    file,
    errorReparseVerbose,
    wrapConf = wconf,
    parseConf = pconf
  )

  withStreamFile(outFile):
    for entry in wrapped:
      # stdout.write(entry)
      file.write(entry)

  if codegens.isSome():
    for gen in codegen:
      writeFile(codegens.get() / gen.filename, gen.code)

    codegen = @[]

when isMainModule:
  dispatchMulti(
    [wrapCpp]
  )
