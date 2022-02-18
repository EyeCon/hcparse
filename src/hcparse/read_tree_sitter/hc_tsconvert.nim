## This module implements conversion of the C and C++ code to nim.
## Translation is performed using simplistic AST-AST rewrite, and requires
## manual correction afterwards.

import
  htsparse/cpp/cpp

import
  std/[strutils, sequtils]

import
  ./hc_tsreader,
  ../hc_impls,
  ../processor/[wrap_store, hc_postprocess],
  ../codegen/hc_codegen

import
  hmisc/core/all,
  hmisc/other/oswrap,
  hmisc/wrappers/[treesitter],
  hmisc/types/colorstring,
  hmisc/algo/namegen,
  hnimast

export parseCppString

proc getIdent*(node: CppNode, c: var StringNameCache): PNode =
  newPIdent(c.fixIdentName(node.strVal(), "f"))

proc wrap*(ntype: NType[PNode], kind: CxxTypeKind): NType[PNode] =
  case kind:
    of ctkPtr:
       return newNType("ptr", @[ntype])

    of ctkDynamicArray:
      return newNType("ptr", @[newNType("UncheckedArray", @[ntype])])

    else:
      raise newImplementKindError(kind)

initPointerWraps(newPType, NType[PNode])

proc toPType*(node: CppNode): NType[PNode] =
  case node.kind:
    of cppTypeDescriptor:
      result = toPType(node[cpfType])
      if cpfDecl in node:
        pointerWraps(node[cpfDecl], result)

    of cppStructSpecifier:
      result = toPType(node["name"])

    else:
      result = newPType(mapTypeName(node))

proc skip*(node: CppNode, idx: int, kind: set[CppNodeKind]): CppNode =
  if node.kind in kind:
    result = node[idx]

  else:
    result = node

proc cxxNamePair*(node: CppNode): CxxNamePair =
  case node.kind:
    of cppQualifiedIdentifier:
      result.cxx.scopes = (
        node[0].cxxNamePair().cxx.scopes &
          node[1].cxxNamePair().cxx.scopes )

    of cppNamespaceIdentifier, cppIdentifier:
      result.cxx.scopes = @[node.strVal()]

    else:
      failNode node

proc conv*(
    node: CppNode,
    str: string,
    c: var StringNameCache,
    conf: CodegenConf,
    fix: CxxFixConf,
  ): PNode =
  template `~`(expr: CppNode): untyped =
    conv(expr, str, c, conf, fix)

  proc toTypeWithAnon(
    node: CppNode, parent, user: Option[CxxNamePair] = none CxxNamePair):
    tuple[nimt: NType[PNode], anon: PNode] =

    let cxx = toCxxTypeWraps(
        node,
        parent = parent,
        user = user).
        postFixEntries(fix, CxxLibImport())

    var anon: seq[NimDecl[PNode]]
    result.nimt = cxx.toNNode(conf, anon)
    result.anon = newPStmtList()
    for an in anon:
      result.anon.add an.toNNode()

  case node.kind:
    of cppTranslationUnit,
       cppCompoundStatement,
       cppExpressionStatement:
      result = newPStmtList()
      for sub in items(node):
        result.add ~sub

    of cppReturnStatement:
      result = nnkReturnStmt.newPTree(
        tern(node.len > 0, ~node[0], newEmptyPNode()))

    of cppCallExpression:
      result = nnkCall.newPTree(~node[0])
      for arg in node[1]:
        result.add ~arg

    of cppTemplateFunction:
      result = newPStmtList()
      var call = nnkBracketExpr.newPTree(~node[0])
      for arg in node[cpfArgs]:
        let (typ, anon) = toTypeWithAnon(arg)
        call.add typ.toNNode()
        result.add anon

      result.add call

    of cppBinaryExpression, cppAssignmentExpression:
      result = newXCall(node{1}.mapOpName(), ~node[0], ~node[1])

    of cppUnaryExpression:
      result = newXCall(node{0}.mapOpName(), ~node[0])

    of cppParenthesizedExpression:
      result = nnkPar.newPTree(~node[0])

    of cppIdentifier,
       cppFieldIdentifier,
       cppTypeIdentifier,
       cppNamespaceIdentifier:
      result = newPident(c.fixIdentName(node.strVal(), "a"))

    of cppFieldExpression:
      # if node{1}.strVal() == "->":
      result = nnkDotExpr.newPTree(~node[0], ~node[1])

    of cppPreprocInclude:
      let file = RelFile(node[0].strVal()[1..^2])
      result = newPTree(
        nnkImportStmt,
        newPIdent(file.withoutExt().getStr() & file.ext()))

    of cppComment, cppPreprocFunctionDef:
      result = newEmptyPNode()

    of cppNumberLiteral:
      result = newPIdent(node.strVal())

    of cppTrue:
      result = newPIdent("true")

    of cppFalse:
      result = newPIdent("false")

    of cppUpdateExpression:
      result = newXCall("postInc", ~node[0])

    of cppStringLiteral:
      result = newPLit(node.strVal().strip(chars = {'"'}))

    of cppPointerExpression:
      if node{0}.strVal() == "*":
        result = newXCall("[]", ~node[0])

      else:
        result = newXCall("addr", ~node[0])

    of cppBreakStatement:
      result = newPBreak()

    of cppSubscriptExpression:
      result = newXCall("[]", ~node["argument"], ~node["index"])

    of cppCastExpression:
      result = nnkCast.newPTree(
        node[cpfType].toPType().toNNode(), ~node["value"])

    of cppNull:
      result = newPIdent("nil")

    of cppPreprocCall, cppPreprocIfdef, cppPreprocDef:
      result = newEmptyPNode()

    of cppSwitchStatement:
      var before = newPStmtList()
      result = newCase(~node[cpfCond])
      var emptyList: seq[PNode]
      for branch in node["body"]:
        case branch.kind:
          of cppComment: discard
          of cppCaseStatement:
            if branch.len == 1:
              emptyList.add ~branch[0]
              continue

            var body = newPStmtList()
            for item in branch[1..^1]:
              body.add ~item

            if "value" notin branch:
              result.addBranch(
                emptyList,
                body[0 .. ^tern(body[^1].kind == nkBreakStmt, 2, 1)].
                  newPStmtList().fixEmptyStmt())

            elif 0 < body.len:
              result.addBranch(
                emptyList &  ~branch["value"],
                body[0 .. ^tern(body[^1].kind == nkBreakStmt, 2, 1)].
                  newPStmtList().fixEmptyStmt())

            else:
              result.addBranch(emptyList & ~branch["value"], body)

            emptyList = @[]

          else:
            # It is possible to arbitrary statements and declarations after
            # the `switch` part, so everything is going to be added before
            # the `case`
            before.add ~branch

      if 0 < before.len:
        before.add result
        return before

    of cppStructSpecifier, cppTypeDefinition:
      var coms: seq[CxxComment]
      var anon: seq[NimDecl[PNode]]
      result = nnkTypeSection.newPTree()

      for ent in toCxxTypeDefinition(node, coms).postFixEntries(fix, CxxLibImport()):
        for en in ent.toNNode(conf, anon):
          result.add toNNode(en)

        for an in anon:
          result.add toNNode(an)

    of cppLabeledStatement:
      result = newPTree(nnkBlockStmt, ~node[0], ~node[1])

    of cppFunctionDefinition, cppTemplateDeclaration:
      var coms: seq[CxxComment]
      let entrs = postFixEntries(@[box(toCxxProc(node, coms))], fix)
      var anon: seq[NimDecl[PNode]]

      var impl = entrs[0].cxxProc.toNNode(conf, anon)
      if node.kind == cppTemplateDeclaration:
        impl.impl = ~node[1]

      else:
        impl.impl = ~node["body"]

      result = newPStmtList()
      for an in anon:
        result.add an.toNNode()

      result.add impl.toNNode()
      # var impl = newPProcDecl(node[cpfDecl].getName())
      # for arg in node[cpfDecl].skip(0, {cppPointerDeclarator})["parameters"]:
      #   var name: string
      #   var argType: NType[PNode]

      #   if cpfDecl in arg:
      #     name = c.fixIdentName(arg.getName(), "a")
      #     argType = arg[cpfType].toPType()
      #     pointerWraps(arg[cpfDecl], argType)

      #   else:
      #     name = "arg"
      #     argType = arg[cpfType].toPType()

      #   impl.addArgument(name, argType)

      # if cpfType in node:
      #   impl.returnType = node[cpfType].toPType()

      # if impl.returnType.isSome():
      #   impl.returnType = impl.returnType.get().withIt do:
      #     pointerWraps(node[cpfDecl], it)


    of cppInitializerList:
      result = newPTree(nnkPar)
      for item in node:
        result.add ~item

    of cppThis:
      result = newPIdent("this")

    of cppGotoStatement:
      # Nim does not have support for 'goto' statements, so translating
      # them literally here, this code would have to be rewritten manually.
      result = newPTree(nnkCommand, newPIdent("cxx_goto"), ~node[0])

    of cppDeleteExpression:
      # There is no corresponding 'delete' expression either, so I wrap it
      # with placeholder proc, it should be supplied from user, or
      # rewritten.
      result = newPTree(nnkCommand, newPIdent("cxx_delete"), ~node[0])

    of cppSyntaxError:
      result = newXCall(newPIdent"CXX_SYNTAX_ERROR", @[newPIdent(node.strVal())])

    of cppStatementIdentifier:
      result = newPIdent(node.strVal())

    of cppInitializerPair:
      result = newPTree(nnkExprColonExpr, ~node[0], ~node[1])

    of cppFieldDesignator:
      result = ~node[0]

    of cppNewExpression:
      result = newXCall(
        newPIdent("new" & node[cpfType].strVal()),
        tern(cpfArgs in node, node[cpfArgs].mapIt(~it), @[]))

    of cppForStatement:
      let update = tern("update" in node, ~node["update"], newEmptyPNode())
      result = newWhile(~node[cpfCond], ~node[^1], update)
      if cpfInit in node:
        result = newBlock(~node[cpfInit], result)

    of cppWhileStatement:
      result = newWhile(newPar ~node[cpfCond], ~node["body"])

    of cppConcatenatedString:
      result = newPLit(node.strVal())

    of cppConditionClause:
      result = ~node[0]

    of cppSizeofExpression:
      result = newXCall("sizeof", ~node["value"])

    of cppTypeDescriptor:
      result = toPType(node).toNNode()

    of cppCharLiteral:
      if node.len != 0 and node[0].kind == cppEscapeSequence:
        result = newPLit('\\')
      else:
        result = newPLit(node.strVal()[1])

    of cppIfStatement:
      result = newIf(
        ~node[cpfCond],
        ~node["consequence"],
        tern(cpfAlter in node, ~node[cpfAlter], nil))

    of cppDoStatement:
      let body = ~node["body"]
      result = newPStmtList(body, newWhile(~node[cpfCond], body))

    of cppDeclaration:
      let decl = node[cpfDecl]
      var value = newEmptyPNode()

      result = newPStmtList()
      # Construct wrapped type declaration. Supplying `parent/name` in case
      # type is an anonymous struct/union.
      let (declType, anon) = toTypeWithAnon(
        node,
        some CxxNamePair(),
        some node.getNameNode().cxxNamePair()
      )

      if "value" in decl:
        if decl[cpfDecl] of cppArrayDeclarator:
          value = newPTree(nnkBracket)
          for item in decl["value"]:
            value.add ~item

          value = newXCall("@", value)

        else:
          value = ~decl["value"]
          if decl["value"] of cppArgumentList:
            # `Instr16 instr16(&emu, &instr);` is converted into
            # `let instr16: Instr16 = initInstr16(addr emu, addr instr)`
            value = newXCall(newPIdent("init" & node[cpfType].strVal()),
                             value[0..^1])



      let name = c.fixIdentName(node.getName(), "f").newPIdent()
      result.add nnkVarSection.newPTree(
        nnkIdentDefs.newPTree(name, declType.toNNode(), value))

    of cppQualifiedIdentifier:
      result = newXCall(".", ~node[0], ~node[1])

    of cppContinueStatement:
      result = newPTree(nnkContinueStmt)

    of cppCatchClause:
      result = newPTree(nnkExceptBranch)
      let param = node["parameters"]
      if param.len == 0:
        result.add ~node["body"]

      else:
        result.add newXCall("as", ~param[0][cpfType], ~param[0][cpfDecl])

    of cppTryStatement:
      result = newPTree(nnkTryStmt, ~node["body"])
      for clause in node[1..^1]:
        result.add ~clause

    of cppThrowStatement:
      result = newPTree(nnkRaiseStmt, ~node[0])

    of cppConditionalExpression:
      result = newPar(
        newIf(
          newPar ~node[cpfCond],
          newPar ~node["consequence"],
          newPar ~node[cpfAlter]
        )
      )

    of cppArgumentList:
      result = newPTree(nnkPar)
      for item in node:
        result.add ~item

    of cppTemplateInstantiation:
      # IIRC template instantiations are used to circumvent some
      # shortcomings of the C++ template system when it comes to splitting
      # things into different files, so nothing to be done here.
      result = newPStmtList()

    else:
      failNode node


when isMainModule:
  for file in walkDir(
      AbsDir"/tmp/infiles",
      AbsFile,
      recurse = true,
      exts = @["h", "c", "hpp", "cpp"]):
  # for file in [AbsFile"/tmp/in.c"]:
    echo file
    var str = file.readFile()
    var c: StringNameCache
    let node = parseCppString(addr str)
    # debug node
    let conf = cxxCodegenConf.withIt do:
      discard

    let fix = baseFixConf.withIt do:
      it.typeStore = newTypeStore()
      it.onGetBind():
        # We are performing code translation here, so there is no need to
        # add any bindings to the generated entries.
        return cxxNoBind()

    let code = node.conv(str, c, conf, fix).`$`
    writeFile(file.withBaseSuffix(file.ext()).withExt("nim"), code)


  echo "done"
