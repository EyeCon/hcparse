import
  ./interop_ir/[wrap_store, wrap_icpp],
  hnimast/[hast_common, pprint],
  hnimast,
  hnimast/[proc_decl, nim_decl]

import
  hmisc/core/all,
  hmisc/macros/argpass,
  hmisc/other/oswrap,
  std/[macros, sequtils, sets, strformat, algorithm]

type
  CodegenConf* = object
    isIcpp*: bool
    declBinds*: Option[tuple[
      decl: CxxBind,
      perOs: seq[(string, CxxBind)]
    ]]

const
  cxxCodegenConf* = CodegenConf(
    isIcpp: true
  )

  cCodegenConf* = cxxCodegenConf.withIt do:
    it.isIcpp = false


func getImport*(conf: CodegenConf): string =
  if conf.isIcpp: "importcpp" else: "importc"

func toNNode*[N](lib: CxxLibImport, asImport: bool): N =
  if asImport:
    result = newNTree[N](
      nnkImportStmt,
      lib.getPathNoExt().mapIt(newNIdent[N](it)).
        foldl(newXCall("/", a, b)))

  else:
    result = newNTree[N](nnkExportStmt, newNIdent[N](lib.getFilename()))


func toNNode*[N](libs: seq[CxxLibImport], asImport: bool): N =
  if libs.len == 0:
    result = newEmptyNNode[N]()

  else:
    let libs = sortedByIt(libs, it)
    if asImport:
      result = newNTree[N](nnkImportStmt)
      for lib in libs:
        result.add lib.getPathNoExt().mapIt(newNIdent[N](it)).foldl(newXCall("/", a, b)):

    else:
      result = newNTree[N](nnkExportStmt)
      for lib in libs:
        result.add newNIdent[N](lib.getFilename())



proc toNNode*[N](
    arg: CxxArg, conf: CodegenConf,
    anon: var seq[NimDecl[N]]
  ): NIdentDefs[N]


proc toNNode*[N](
    t: CxxTypeUse, conf: CodegenConf,
    anon: var seq[NimDecl[N]]
  ): NType[N] =

  case t.kind:
    of ctkIdent:
      result = newNNType[N](t.nimName, @[])

    of ctkPtr:
      if t.wrapped of ctkIdent:
        case t.wrapped.nimName:
          of "char": result = newNNType[N]("cstring", @[])
          of "void": result = newNNType[N]("pointer", @[])
          else: result = newNType[N]("ptr", @[toNNode[N](t.wrapped, conf, anon)])

      else:
        result = newNType[N]("ptr", @[toNNode[N](t.wrapped, conf, anon)])

    of ctkProc:
      var pragma: Pragma[N]
      if ctfNoCdeclProc notin t.flags:
        pragma = newNPragma[N](newNIdent[N]("cdecl"))

      result = newProcNType[N](
        t.arguments.mapIt(toNNode[N](it, conf, anon)),
        toNNode[N](t.returnType, conf, anon), pragma)

    of ctkDynamicArray:
      result = newNType[N]("ptr", @[
        newNType[N]("UncheckedArray", @[
          toNNode[N](t.wrapped, conf, anon)])])

    of ctkAnonObject:
      var def = t.objDef
      def.decl.name = t.objParent & t.objUser
      let gen = toNNode[N](def, conf, anon)
      anon.add gen
      result = newNNType[N](def.nimName)

    of ctkAnonEnum:
      var def = t.enumDef
      def.decl.name = t.enumParent & t.enumUser
      let gen = toNNode[N](def, conf)
      anon.add gen
      result = newNNType[N](def.nimName)

    else:
      raise newImplementKindError(t)

proc toNNode*[N](
    t: CxxTypeDecl, conf: CodegenConf,
    anon: var seq[NimDecl[N]]
  ): NType[N] =

  newNType[N](
    t.nimName,
    t.genParams.mapIt(newNNType[N](it.name.nim, @[])))

proc toNNode*[N](
    arg: CxxArg, conf: CodegenConf,
    anon: var seq[NimDecl[N]]
  ): NIdentDefs[N] =

  newNIdentDefs[N](
    arg.nimName,
    toNNode[N](arg.nimType, conf, anon),
    value = some newEmptyNNode[N]())

proc toNimComment*(com: seq[CxxComment]): string =
  for idx, c in com:
    if idx > 0: result.add "\n"
    result.add c.text

proc toNNode*[N](
    field: CxxField, conf: CodegenConf,
    anon: var seq[NimDecl[N]]
  ): ObjectField[N] =

  result = ObjectField[N](
    isTuple: false,
    name: field.nimName(),
    isExported: true,
    docComment: field.docComment.toNimComment(),
    fldType: toNNode[N](field.getType(), conf, anon))

  let cxx = field.cxxName.cxxStr()
  if cxx != field.nimName():
    result.addPragma(
      conf.getImport(), newNLit[N, string](field.cxxName.cxxStr()))


proc toNNode*[N](header: CxxBind, conf: CodegenConf, name: string): seq[N] =
  case header.kind:
    of cbkGlobal:
      result.add newIdentColonExpr(
        "header", newNLit[N, string](header.global))

    of cbkAbsolute:
      result.add newIdentColonExpr(
        "header", newNLit[N, string](header.file.string))

    of cbkPNode:
      result.add newIdentColonExpr(
        "header", newNLit[N, string](header.other))

    of cbkNone:
      discard

    of cbkDynamicPatt:
      result.add newIdentColonExpr(
        "dynlib", newNLit[N, string](header.dynPattern))

    of cbkDynamicExpr:
      result.add newIdentColonExpr(
        "dynlib", newNIdent[N](header.dynExpr))

    of cbkDynamicCall:
      result.add newIdentColonExpr(
        "dynlib", newXCall(newNIdent[N](header.dynExpr)))

  if header.icpp.len > 0:
    let str =
      if conf.isIcpp:
        $header.icpp

      else:
        assertKind(header.icpp[0], { ipkTextPart }, $header.icpp)
        $header.icpp[0]

    if name != str:
      result.add newIdentColonExpr[N](
        conf.getImport(),
        newPLit[N, string](str))

    else:
      result.add newNIdent[N](conf.getImport)

  else:
    result.add newNIdent[N](conf.getImport)

proc toNNode*[N](
    def: CxxAlias, conf: CodegenConf,
    anon: var seq[NimDecl[N]]
  ): tuple[alias: AliasDecl[N], extra: seq[NimDecl[N]]] =

  result.alias = newAliasDecl(
    toNNode[N](def.decl, conf, anon),
    toNNode[N](def.baseType, conf, anon),
    isDistinct = false
  )

  if def.baseType of ctkProc:
    let base = def.baseType
    if
      base[^1] of ctkPtr and
      base[^1][0] of ctkIdent and
      base[^1][0].podKind == cptVoid:
      var newDef = def
      newDef.nimName = newDef.nimName & "Nim"
      discard newDef.baseType.arguments.pop()
      newDef.baseType.flags.incl ctfNoCdeclProc

      result.extra.add toNimDecl[N](newAliasDecl(
        toNNode[N](newDef.decl, conf, anon),
        toNNode[N](newDef.baseType, conf, anon),
        isDistinct = false
      ))

proc toNNode*[N](
    def: CxxProc,
    conf: CodegenConf,
    anon: var seq[NimDecl[N]],
    onConstructor: CxxTypeKind = ctkIdent
  ): ProcDecl[N] =

  result = newProcDecl[N](def.nimName)
  result.exported = true
  result.docComment = def.docComment.toNimComment()

  if cpfExportc in def.flags:
    result.addPragma("exportc", newNLit[N, string](def.cxxName.cxxStr()))

  else:
    result.addPragma toNNode[N](
      def.getCbindAs(ctkIdent), conf, def.nimName)

  if cpfVariadic in def.flags:
    result.addPragma("varargs")

  if def.isConstructor and onConstructor == ctkIdent:
    result.addPragma("constructor")


  # nim's overload-resolution-in-generics magic
  proc_decl.`returnType=`(
    result, toNNode[N](def.getReturn(onConstructor), conf, anon))

  if def.methodOf.isSome():
    result.addArgument(
      "this", toNNode[N](def.methodOf.get(), conf, anon))

  for arg in def.arguments:
    result.addArgument toNNode[N](arg, conf, anon)

proc toNNode*[N](
    obj: CxxObject, conf: CodegenConf,
    anon: var seq[NimDecl[N]]
  ): seq[NimDecl[N]] =

  var res = newObjectDecl[N](obj.nimName)
  res.docComment = obj.docComment.toNimComment()
  res.addPragma("bycopy")
  if obj.kind == cokUnion:
    res.addPragma("union")
  # res.addPragma("inheritable")
  # res.addPragma("byref")

  res.addPragma toNNode[N](obj.cbind, conf, obj.nimName)
  # res.addPragma("header", toNNode[N](obj.header.get()))
  # res.addPragma(conf.getImport(), newNLit[N, string](obj.getIcppStr()))

  for field in obj.mfields:
    res.add toNNode[N](field, conf, anon)

  result.add toNimDecl(res)

  for meth in obj.methods:
    result.add toNNode[N](meth, conf, anon, ctkPtr)

  for n in obj.nested:
    result.add toNNode[N](n, conf, anon)

proc toNNode*[N](obj: CxxForward, conf: CodegenConf): ObjectDecl[N] =
  result = newObjectDecl[N](obj.nimName)
  result.addPragma("bycopy")
  result.addPragma("incompleteStruct")
  result.addPragma toNNode[N](obj.cbind, conf, obj.nimName)
  result.docComment.add toNimComment(obj.docComment)

proc toNNode*[N](field: CxxEnumValue, conf: CodegenConf): EnumField[N] =
  result = makeEnumField(
    field.nimName, some newNLit[N, BiggestInt](field.value))

  result.docComment = toNimComment(field.docComment)

proc toNNode*[N](en: CxxEnum, conf: CodegenConf): EnumDecl[N] =
  result = newEnumDecl[N](en.nimName)

  var fieldList: seq[EnumField[N]]
  var values = en.values.sortedByIt(it.value)

  var visited: HashSet[BiggestInt]
  for value in values:
    if value.value notin visited:
      visited.incl value.value
      result.add toNNode[N](value, conf)

  result.docComment.add toNimComment(en.docComment)


proc toNNode*[N](
    entry: CxxEntry, conf: CodegenConf,
    anon: var seq[NimDecl[N]]
  ): seq[NimDecl[N]] =

  case entry.kind:
    of cekObject:
      result.add toNNode[N](entry.cxxObject, conf, anon)

    of cekEnum:
      result.add toNNode[N](entry.cxxEnum, conf).toNimDecl()

    of cekProc:
      result.add toNNode[N](
        entry.cxxProc, conf, anon, ctkPtr).toNimDecl()

    of cekForward:
      result.add toNNode[N](entry.cxxForward, conf)

    of cekEmpty:
      discard

    of cekAlias:
      let a = entry.cxxAlias
      if a.baseType of ctkIdent and
         a.decl.nimName() == a.baseType.nimName():
        # WARNING unconditionally discarding typedefs might be an invalid
        # behavior
        discard

      else:
        let (alias, extra) = toNNode[N](a, conf, anon)
        result.add alias.toNimDecl()
        result.add extra

    else:
      raise newImplementKindError(entry)

proc toNNode*[N](entries: seq[CxxEntry], conf: CodegenConf): seq[NimDecl[N]] =
  var
    types: seq[NimTypeDecl[N]]
    other: seq[NimDecl[N]]
    anon: seq[NimDecl[N]]
    visited: HashSet[CxxNamePair]

  for item in entries:
    if item of cekEmpty:
      discard

    elif item.name notin visited:
      if item of cekForward:
        visited.incl item.name

      for conv in toNNode[N](item, conf, anon):
        if conv of nekTypeKinds:
            types.add toNimTypeDecl(conv)

        else:
          other.add conv

  for conv in anon:
    if conv of nekTypeKinds:
      types.add toNimTypeDecl(conv)

    else:
      other.add conv

  result.add toNimDecl(sortedByIt(types, it.getName()))
  result.add other

proc genDynDecl*[N](conf: CodegenConf): N =
  result = newNtree[N](nnkStmtList)
  if conf.declBinds.isSome():
    let (varDecl, perOs) = conf.declBinds.get()
    let expr = vardecl.dynExpr
    var check = newNTree[N](nnkWhenStmt)


    let pathname = expr & "PathOverride"
    let sect = newSection(
        nnkConstSection,
        name     = pathname,
        ctype    = newEmptyNNode[N](),
        expr     = newNLit[N, string](""),
        pragmas  = @[newNident[N]("strdefine")])

    check.addBranch(
      newXCall("defined", newNIdent[N](pathname)),
      newNTree[N](
        nnkStmtList,
        sect,
        newConst(expr, newNIdent[N](pathname), true)))

    for (os, decl) in perOs:
      check.addBranch(
        newXCall("defined", newNIdent[N](os)),
        newConst(expr, newNLit[N, string](decl.dynPattern), true))

    result.add check




proc toNNode*[N](file: CxxFile, conf: CodegenConf): N =
  result = newNTree[N](nnkStmtList)

  result.add pquote do:
    {.push warning[UnusedImport]:off.}

  var imports = file.imports
  imports.incl file.getBindImports()

  var relImports: seq[CxxLibImport]

  for dep in items(imports):
    if dep.getLibrary() == file.getLibrary():
      let (pDep, pFile) = (dep.getFile(), file.getFile())

      let (depth, parts) = importSplit(
        AbsDir"/tmp" / pFile, AbsDir"/tmp" / pDep)

      let depthDots = tern(depth == 0, @["."], mapIt(0 ..< depth, ".."))
      let newImp = cxxLibImport(file.getLibrary(), depthDots & parts)

      relImports.add newIMp
      # result.add toNNode[N](newImp, true)

    else:
      let newImp = cxxLibImport(
        dep.getLibrary(), dep.getLibrary() & dep.importPath)

      relImports.add newImp
      # result.add toNNode[N](newImp, true)

  result.add toNNode[N](relImports, true)

  for exp in items(file.exports):
    result.add toNNode[N](exp, false)

  result.add genDynDecl[N](conf)
  for decl in toNNode[N](file.entries, conf):
    result.add toNNode[N](decl)

proc toString*(file: CxxFile, conf: CodegenConf): string =
  let node = toNNode[PNode](file, conf)
  return toPString(node)

proc toString*(entries: seq[CxxEntry], conf: CodegenConf): string =
  var gen = newPStmtList()
  gen.add genDyndecl[PNode](conf)
  gen.add toNNode[PNode](entries, conf).toNNode()

  toPString(gen)

proc toString*(files: seq[CxxFile], conf: CodegenConf): string =
  for file in files:
    result.add &">>> {file.savePath}\n{file.toString(conf)}\n"

import std/[strutils, strformat]

proc printNumerated*(str: string, numRange: Slice[int]): string =
  var num = 1
  for line in splitLines(str):
    if num in numRange:
      echo &"{num:<4}| {line}"

    inc num

  return str
