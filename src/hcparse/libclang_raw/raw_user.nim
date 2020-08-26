import macros, sugar, strformat, lenientops, bitops, sequtils, options,
       terminal, shell, strutils, parseutils

import hpprint, hpprint/hpprint_repr

import hmisc/[hexceptions, hdebug_misc]
import hmisc/helpers
import hmisc/types/[hnim_ast, colorstring]
# import compiler/[parser, llstream, idents, options,
#                  pathutils, astalgo, msgs,
#                  ast, renderer, lineinfos]

import compiler/[ast, renderer, lineinfos]
import packages/docutils/rstast
import std/decls

import index, documentation, cxstring

proc isNil*(tu: CXTranslationUnit): bool =
  cast[ptr[CXTranslationUnitImpl]](tu) == nil


#==========================  String conversion  ==========================#

proc `$`(cxstr: CXString): string =
  let str = clang_getCString(cxstr)
  result = $str
  clang_disposeString(cxstr)

proc `$`(cursor: CXCursor): string = $clang_getCursorSpelling(cursor)
proc `$`(cxtype: CXType): string = $clang_getTypeSpelling(cxtype)
proc `$`(cxkind: CXCursorKind): string =
  $clang_getCursorKindSpelling(cxkind)

#=====================  Cursor kind/type operations  =====================#

proc cxKind*(cursor: CXCursor): CXCursorKind =
  clang_getCursorKind(cursor)

proc expectKind*(cursor: CXCursor, kind: CXCursorKind) =
  if cursor.cxKind != kind:
    raiseAssert(&"Expected cursor kind {kind}, but got {cursor.cxKind()}")


proc cxType*(cursor: CXCursor): CXType =
  clang_getCursorType(cursor)

proc cxKind*(cxtype: CXType): CXTypeKind = cxtype.kind

proc expectKind*(cxtype: CXType, kind: CXTypeKind) =
  if cxtype.cxKind != kind:
    raiseAssert(&"Expected type kind {kind}, but got {cxtype.cxKind()}")

proc argc*(cxtype: CXType): int =
  cxtype.expectKind(CXType_FunctionProto)
  clang_getNumArgTypes(cxtype).int

proc argc*(cursor: CXCursor): int =
  cursor.cxType().argc()

proc nthArg*(cxtype: CXType, idx: int): CXType =
  assert idx < cxtype.argc()
  clang_getArgType(cxtype, cuint(idx))


#===========================  Location checks  ===========================#

proc isFromMainFile*(cursor: CXCursor): bool =
  cursor.
    clang_getCursorLocation().
    clang_Location_isFromMainFile() != cint(0)

#==========================  Subnode visitors  ===========================#

proc toClientData*[T](val: var T): CXClientData =
  CXClientData(addr val)

proc toCursorVisitor*(
  impl: proc(cursor, parent: CXCursor,
             clientData: pointer): CXChildVisitResult {.cdecl.}): CXCursorVisitor =
  CXCursorVisitor(impl)


proc clang_visitChildren[T](
  cursor: CXCursor,
  callback: tuple[
    data: T,
    impl: proc(cursor, parent: CXCursor,
               clientData: pointer): CXChildVisitResult {.cdecl.}]) =

  var data = callback.data
  discard cursor.clang_visitChildren(
    toCursorVisitor(callback.impl),
    toClientData(data)
  )

func takesOnlyMutable*[T](v: var T) = discard
template isMutable*(v: typed): untyped = compiles(takesOnlyMutable(v))

macro makeVisitor(captureVars, body: untyped): untyped =
  var immutableCopies = newStmtList()
  captureVars.assertNodeKind({nnkBracket})
  let tupleData = nnkPar.newTree: collect(newSeq):
    for capture in captureVars:
      capture.assertNodeKind({nnkIdent})
      immutableCopies.add quote do:
        when not isMutable(`capture`):
          var `capture` = `capture`

      newColonExpr(capture, newCall("addr", capture))

  let byaddrid = ident "byaddr"
  let dataUnpack = newStmtList: collect(newSeq):
    for capture in captureVars:
      quote do:
        var `capture` {.`byaddrid`.} = data[].`capture`[]

  let
    cursorId = ident "cursor"
    parentId = ident "parent"

  result = quote do:
    `immutableCopies`
    var data {.inject.} = `tupleData`
    type Data = typeof(data)
    proc visitor(`cursorId`, `parentId`: CXCursor,
                 clientData: pointer): CXChildVisitResult {.cdecl.} =
      let data {.inject.} = cast[ptr[Data]](clientData)
      `dataUnpack`
      `body`

    (data, visitor)

#=========================  Filtering subnodes  ==========================#

proc children*(cursor: CXCursor): seq[CXCursor] =
  var buf: seq[CXCursor]
  var ddd: int
  cursor.clangVisitChildren do:
    makeVisitor [buf, ddd]:
      buf.add cursor
      return CXChildVisit_Continue

  return buf

proc `[]`*(cursor: CXCursor, idx: int): CXCursor =
  var
    res: CXCursor
    cnt = 0

  cursor.clangVisitChildren do:
    makeVisitor [res, cnt, idx]:
      if cnt == idx:
        res = cursor
        return CXChildVisit_Break
      else:
        inc cnt
        return CXChildVisit_Continue

  if cnt < idx:
    raiseAssert("Cursor {cursor} no child at index {idx}")
  else:
    return res

proc len*(cursor: CXCursor): int =
  var cnt = 0
  cursor.clangVisitChildren do:
    makeVisitor [cnt]:
      inc cnt
      return CXChildVisit_Continue

  return cnt

#============================  Documentation  ============================#

proc comment*(cursor: CXCursor): CXComment =
  cursor.clang_Cursor_getParsedComment()

proc cxKind*(comment: CXComment): CXCommentKind =
  comment.clang_Comment_getKind()

proc `$`*(comment: CXComment): string =
  $comment.clang_FullComment_getAsHTML() # NOTE it seems like libclang
  # API does not provide a way to get full comment string as raw string.

iterator children*(comment: CXComment): CXComment =
  for i in 0..clang_Comment_getNumChildren(comment):
    yield comment.clang_Comment_getChild(cuint(i))

proc len*(comment: CXComment): int =
  clang_Comment_getNumChildren(comment).int

proc `[]`*(comment: CXComment, idx: int): CXComment =
  assert idx < comment.len
  clang_Comment_getChild(comment, cuint(idx))

proc objTreeRepr*(comment: CXComment): ObjTree =
  case comment.cxKind:
    of CXComment_Text:
      pptConst $comment.clang_TextComment_getText()
    of CXComment_ParamCommand:
      pptObj(
        $comment.cxKind,
        [(
          $clang_ParamCommandComment_getParamName(comment),
          pptSeq(toSeq(comment.children).mapIt(it.objTreeRepr()))
          # objTreeRepr(comment[0])
        )]
      )
    of CXComment_InlineCommand:
      let args: seq[string] = collect(newSeq):
        for i in 0 ..< clang_InlineCommandComment_getNumArgs(comment):
          $clang_InlineCommandComment_getArgText(comment, cuint(i))

      pptObj(
        $comment.cxKind,
        [(
          $clang_InlineCommandComment_getCommandName(comment),
          pptSeq(
            args.mapIt(it.pptConst) &
            toSeq(comment.children).mapIt(it.objTreeRepr())
          )
        )]
      )
    of CXComment_BlockCommand:
      pptObj(
        $comment.cxKind,
        [(
          $clang_BlockCommandComment_getCommandName(comment),
          pptSeq(toSeq(comment.children).mapIt(it.objTreeRepr()))
          # objTreeRepr(comment[0])
        )]
      )
    else:
      if comment.len == 0:
        pptObj($comment.cxKind,
               pptConst($comment.clang_FullComment_getAsXML()))
      else:
        pptObj($comment.cxKind,
               toSeq(comment.children).mapIt(it.objTreeRepr()))

proc retType*(cursor: CXCursor): CXType =
  cursor.expectKind(CXCursor_FunctionDecl)
  cursor.cxType().clang_getResultType()

proc newRstNode*(
  kind: RstNodeKind, subnodes: varargs[PRstNode]): PRstNode =
  result = rstast.newRstNode(kind)
  for node in subnodes:
    result.add node

proc toRstNode*(comment: CXComment): PRstNode =
  case comment.cxKind:
    of CXComment_Text:
      return rnLeaf.newRstNode($clang_TextComment_getText(comment))
    of CXComment_FullComment, CXComment_Paragraph:
      result = rnInner.newRstNode()
      for subnode in comment.children():
        result.add subnode.toRstNode()
    of CXComment_Null:
      return rnLeaf.newRstNode("")
    of CXComment_InlineCommand:
      return rnLiteralBlock.newRstNode(
        "!!! TODO !!!\n" &
        comment.objTreeRepr().pstring()
      )
    of CXComment_ParamCommand:
      return rnInner.newRstNode(
        @[
          rnEmphasis.newRstNode(
            rnInner.newRstNode(
              $clang_ParamCommandComment_getParamName(comment)
            )
          )
        ] & toSeq(comment.children).mapIt(it.toRstNode())
      )
    of CXComment_BlockCommand:
      return rnInner.newRstNode(
        @[
          rnEmphasis.newRstNode(
            rnInner.newRstNode(
              $clang_BlockCommandComment_getCommandName(comment)
            )
          )
        ] & toSeq(comment.children).mapIt(it.toRstNode())
      )
    of CXComment_VerbatimBlockCommand:
      return rnCodeBlock.newRstNode(
        rnLiteralBlock.newRstNode(
          rnLeaf.newRstNode(
            $clang_VerbatimBlockLineComment_getText(comment))))
    of CXComment_VerbatimLine:
      return rnInterpretedText.newRstNode(
        $clang_VerbatimLineComment_getText(comment))
    else:
      echo "died".toRed()
      echo comment.objTreeRepr().pstring()
      raiseAssert("#[ IMPLEMENT ]#")

proc toNimDoc*(comment: CXComment): string =
  # echo comment.objTreeRepr().pstring()
  comment.toRstNode().renderRstToRst(result)

#=============================  Converters  ==============================#

proc fromElaboratedNType(cxtype: CXType): NType =
  ($cxtype).
    dropPrefix("enum ").
    dropPrefix("struct ").
    mkNType()

proc getPointee*(cxType: CXType): CXType =
  cxtype.expectKind(CXType_Pointer)
  clang_getPointeeType(cxtype)

proc objTreeRepr*(cxtype: CXType): ObjTree =
  case cxtype.cxKind:
    of CXType_Pointer:
      pptObj("ptr", cxtype.getPointee().objTreeRepr())
    else:
      pptObj($cxtype.cxkind, pptConst($cxtype))

proc tokens*(cursor: CXCursor, tu: CXTranslationUnit): seq[string] =
  let range: CXSourceRange   = clang_getCursorExtent(cursor);
  var tokens: ptr[CXToken]
  var nTokens: cuint = 0
  clang_tokenize(tu, range, addr tokens, addr nTokens)

  for i in 0 ..< nTokens:
    result.add $clang_getTokenSpelling(
      tu, (cast[ptr UncheckedArray[CXToken]](tokens))[i])


proc objTreeRepr*(cursor: CXCursor): ObjTree =
  if cursor.len  == 0:
    pptObj($cursor.cxkind, pptConst($cursor))
  else:
    pptObj(
      $cursor.cxkind,
      toSeq(cursor.children).mapIt(it.objTreeRepr()))


proc objTreeRepr*(cursor: CXCursor, tu: CXTranslationUnit): ObjTree =
  if cursor.len  == 0:
    pptObj($cursor.cxkind,
           initPrintStyling(fg = fgYellow),
           pptConst(cursor.tokens(tu).join(" "),
                    initPrintStyling(fg = fgGreen)))
  else:
    let ctype = pptConst(
      $cursor.cxType,
      initPrintStyling(fg = fgBlue, style = {styleItalic, styleDim}))
    pptObj(
      ($cursor.cxkind).toMagenta() & " " & $cursor,
      @[ctype] & toSeq(cursor.children).mapIt(it.objTreeRepr(tu))
    )

proc treeRepr*(cursor: CXCursor, tu: CXTranslationUnit): string =
  cursor.objTreeRepr(tu).treeRepr()

proc treeRepr*(cursor: CXCursor): string =
  cursor.objTreeRepr().treeRepr()

proc lispRepr*(cxtype: CXType): string =
  cxtype.objTreeRepr().lispRepr()

proc toNType*(cxtype: CXType): NType =
  # echo cxtype.objTreeRepr().treeRepr()
  case cxtype.cxKind:
    of CXType_Bool: mkNType("bool")
    of CXType_Int: mkNType("int")
    of CXType_Void: mkNType("void")
    of CXType_UInt: mkNType("cuint")
    of CXType_LongLong: mkNType("clonglong")
    of CXType_ULongLong: mkNType("culonglong")
    of CXType_Double: mkNType("cdouble")
    of CXType_Typedef: mkNType($cxtype) # XXX typedef processing -
    of CXType_Elaborated:
      fromElaboratedNType(cxtype)
    of CXType_Pointer:
      let pointee = cxtype.getPointee()
      case pointee.cxkind:
        of CXType_Char_S:
          mkNType("cstring")
        else:
          # echo "NESTED ".toYellow(), cxtype.lispRepr()
          mkNType("ptr", [toNType(pointee)])
    else:
      echo "CANT CONVERT: ".toRed({styleItalic}),
        cxtype.kind, " ", cxtype.lispRepr().toGreen()
      mkNType("!!!")

proc dropPOD*(cxtype: CXType): string =
  case cxtype.cxKind:
    of CXType_Elaborated:
      cxtype.fromElaboratedNType().head
    of CXType_Pointer:
      cxtype.getPointee().dropPOD()
    of CXType_Typedef:
      ($cxtype).dropPrefix("const ")
    else:
      ""

proc toPIdentDefs*(cursor: CXCursor): PIdentDefs =
  result.varname = $cursor
  if result.varname.len == 0:
    result.varname = "arg" & $cursor.cxType().dropPOD()

  result.vtype = cursor.cxType.toNType()


#==========================  Toplevel visitors  ==========================#

type
  RewriteContext = object
    resultNode*: PNode
    prefix*: string
    typePrefix*: string
    translationUnit*: CXTranslationUnit
    dropTypeSubseqs*: seq[string]

proc simplifyFuncName(cursor: CXCursor, context: var RewriteContext): string =
  let unprefix = ($cursor).dropPrefix(context.prefix)

  if cursor.argc() > 0:
    let
      first = cursor.cxType().nthArg(0)
      rawName = first.dropPOD()
      name = rawName.dropPrefix(context.typePrefix)

    if name.len > 0:
      return unprefix.
        dropPrefix(name & "_").
        dropPrefix(rawName & "_")
  else:
    return unprefix

proc isAliasTypedef*(cursor: CXCursor): bool =
  if cursor.len > 0:
    cursor[0].cxKind in {
      CXCursor_EnumDecl,
      CXCursor_StructDecl
    }
  else:
    false

proc visitFunction(cursor: CXCursor, context: var RewriteContext) =
  cursor.expectKind(CXCursor_FunctionDecl)
  let arguments = cursor.children.
    filterIt(it.cxKind == CXCursor_ParmDecl).
    mapIt(it.toPIdentDefs())

  context.resultNode.add mkProcDeclNode(
    head = newPIdent(cursor.simplifyFuncName(context)),
    rtype = some(toNType(cursor.retType())),
    args = arguments,
    impl = newPIdent("impl"),
    comment = cursor.comment().toNimDoc()
  )

proc visitAliasTypedef*(cursor: CXCursor, context: var RewriteContext) =
  echo "Alias typedef: ", cursor

proc toEnumValue*(cursor: CXCursor, tu: CXTranslationUnit): Option[PNode] =
  cursor.expectKind CXCursor_EnumConstantDecl
  let val = cursor[0]
  case val.cxKind:
    of CXCursor_IntegerLiteral:
      let tok = val.tokens(tu)[0]
      var res: int
      if tok.len > 2 and tok[1] == 'x':
        discard parseHex(tok, res)
      else:
        discard parseInt(tok, res)

      return some(newPLit(res))
    of CXCursor_OverloadCandidate:
      return none(PNode)
    else:
      echo val.treeRepr(tu)
      # raiseAssert(&"#[ IMPLEMENT {val.cxkind} ]#")


proc visitEnumDecl*(cursor: CXCursor, context: var RewriteContext) =
  let enumName = ($cursor.cxType).dropPrefix("enum ")

  let names = @[enumName].concat: collect(newSeq): # NICE
      for elem in cursor.children:
        $elem

  let pref = names.commonPrefix()

  let enumPref = enumName.
    dropLongestSubseq(context.dropTypeSubseqs).
    dropPrefix(context.typePrefix).
    splitCamel().
    mapIt(it[0].toLowerAscii()).
    join("")

  var en = PEnum(name: enumName)

  for elem in cursor.children:
    en.values.add (
      name: ($elem).dropPrefix(pref).dropPrefix("_").addPrefix(enumPref),
      value: elem.toEnumValue(context.translationUnit))

  context.resultNode.add en.toNNode(standalone = true)


proc visitStructDecl*(cursor: CXCursor, context: var RewriteContext) =
  echo "struct decl: ", cursor
  echo cursor.treeRepr(context.translationUnit)
  let structName = ($cursor.cxType).dropPrefix("struct ")

  var resType = PObject(name: mkNType(structName))

  for subn in cursor.children:
    subn.expectKind CXCursor_FieldDecl

    resType.flds.add PField(
      isKind: false,
      isTuple: false,
      name: $subn,
      fldType: subn.cxType.toNType()
    )

  context.resultNode.add resType.toNNode(standalone = true)

#================================  Main  =================================#

proc parseTranslationUnit(
  trIndex: CXIndex,
  filename: string,
  cmdline: seq[string] = @[],
  trOptions: set[CXTranslationUnit_Flags] = {}): CXTranslationUnit =

  var flags: int
  for opt in trOptions:
    flags = bitor(flags, int(opt))

  let argc = cmdline.len
  let cmdline = allocCSTringArray(cmdline)

  result = clang_parseTranslationUnit(
    trIndex, filename.cstring, cmdline, cint(argc), nil, 0, cuint(flags))

  deallocCStringArray(cmdline)


proc main() =
  let trIndex = clang_createIndex(0, 0);
  let unit = parseTranslationUnit(trIndex, "/usr/include/clang-c/Index.h")


  if unit.isNil:
    raiseAssert "Unable to parse translation unit. Quitting."

  let cursor: CXCursor = clang_getTranslationUnitCursor(unit)

  var context = RewriteContext(
    resultNode: nkStmtList.newTree(),
    prefix: "clang_",
    typePrefix: "CX",
    translationUnit: unit,
    dropTypeSubseqs: @["CXX"]
  )

  cursor.clangVisitChildren do:
    makeVisitor [context]:
      if cursor.isFromMainFile():
        case cursor.cxkind:
          of CXCursor_FunctionDecl:
            visitFunction(cursor, context)
            return CXChildVisit_Continue
          of CXCursor_TypedefDecl:
            if cursor.isAliasTypedef():
              visitAliasTypedef(cursor, context)
            else:
              return CXChildVisit_Recurse
          of CXCursor_EnumDecl:
            visitEnumDecl(cursor, context)
          of CXCursor_StructDecl:
            visitStructDecl(cursor, context)
          else:
            discard

      return CXChildVisit_Recurse

  "../libclang.nim".writeFile($context.resultNode)


when isMainModule:
  try:
    main()
  except:
    pprintErr
