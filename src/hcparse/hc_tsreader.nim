import
  htsparse/cpp/cpp

import
  std/[json]

import
  ./hc_types,
  ./hc_typeconv,
  ./interop_ir/wrap_store

import
  hmisc/core/all,
  hmisc/wrappers/[treesitter],
  hmisc/other/oswrap

export parseCppString


proc getHaxdoc*(conf: WrapConf, parent: seq[CppNode]): JsonNode =
  newJNull()

proc primitiveName*(node: CppNode): string =
  proc aux(ts: TsCppNode): string =
    if ts.len == 0:
      result = node.getBase()[ts]

    elif ts.len(unnamed = true) == 2:
      result = node.getBase()[ts{0}] & " " & aux(ts{1})

    else:
      raise newImplementKindError(
        node, ts.treeRepr(node.getBase(), unnamed = true))

    if result.len == 0:
      echo ts.len
      echo ts.len(unnamed = true)
      echo node.getBase()[ts]


  return aux(node.getTs())

proc mapOpName*(node: CppNode): string =
  case node.strVal():
    of "|": "or"
    of "<<": "shl"
    of ">>": "shr"
    of "&": "and"
    of "^": "xor"
    of "~": "not"
    of "!": "not" # QUESTION what is the difference between ~ and !
    else: node.strVal()

proc mapTypeName*(node: CppNode): string =
  if node.kind == cppTypeIdentifier:
    node.strVal()

  else:
    mapPrimitiveName(node.primitiveName())

proc toCxxType*(conf: WrapConf, node: CppNode): CxxTypeUse =
  case node.kind:
    of cppTypeIdentifier, cppSizedTypeSpecifier, cppPrimitiveType:
      result = cxxTypeUse(cxxPair(
        mapTypeName(node),
        cxxName(@[node.strVal()])))

    else:
      raise newImplementKindError(node, node.treeRepr())



proc toCxxMacro*(conf: WrapConf, node: CppNode): CxxMacro =
  assertKind(node, {cppPreprocFunctionDef, cppPreprocDef})

  result = cxxMacro(cxxPair(node["name"].strVal()))

  # result = CxxMacro(
  #   haxdocIdent: conf.getHaxdoc(@[]),
  #   name: (node["name"].strVal)
  # )

  if "parameters" in node:
    for arg in node["parameters"]:
      result.arguments.add arg.strVal()

  # TODO convert body


proc toCxxEnum*(conf: WrapConf, node: CppNode): CxxEnum =
  var name: CxxNamePair

  if "name" in node:
    name = cxxPair(node["name"].strVal())

  result = cxxEnum(name)

  for en in node["body"]:
    case en.kind:
      of cppEnumerator:
        result.values.add CxxEnumValue(
          name: cxxPair(en["name"].strVal()),
          value: 0 # TODO convert from `en["value"]`
        )

      of cppComment:
        result.values[^1].comment.add en.strVal()

      else:
        raise newImplementKindError(en)


proc skipPointer(node: CppNode): CppNode =
  case node.kind:
    of cppPointerDeclarator: skipPointer(node[0])
    else: node

template initPointerWraps*(newName, Type: untyped): untyped =
  proc pointerWraps(node: CppNode, ftype: var TYpe) =
    case node.kind:
      of cppPointerDeclarator:
        ftype = newName("ptr", @[ftype])
        if node[0] of cppTypeQualifier:
          pointerWraps(node[1], ftype)

        else:
          pointerWraps(node[0], ftype)

      of cppArrayDeclarator:
        ftype = newName("array", @[ftype])
        pointerWraps(node[0], ftype)

      of cppInitDeclarator,
         cppTypeQualifier #[ TODO convert for CxxType? ]#:
        pointerWraps(node[0], ftype)

      of cppAbstractPointerDeclarator:
        ftype = newName("ptr", @[ftype])
        if node.len > 0:
          pointerWraps(node[0], ftype)

      of {
        cppFieldIdentifier,
        cppTypeIdentifier,
        cppIdentifier,
        cppFunctionDeclarator
      }:
        discard

      else:
        raise newImplementKindError(
          node, node.strVal() & "\n" & node.treeRepr())

initPointerWraps(cxxTypeUse, CxxTypeUse)

proc getName*(node: CppNode): string =
  case node.kind:
    of cppFieldIdentifier,
       cppTypeIdentifier,
       cppIdentifier,
       cppPrimitiveType:
      node.strVal()

    of cppArrayDeclarator, cppFunctionDeclarator:
      node[0].getName()

    of cppDeclaration, cppInitDeclarator:
      node["declarator"].getName()

    else:
      if node.len > 0:
        node[^1].getName()

      else:
        raise newImplementKindError(node, node.treeRepr())

proc toCxxArg*(conf: WrapConf, node: CppNode, idx: int): CxxArg =
  assertKind(node, {cppParameterDeclaration})
  result = CxxArg(haxdocIdent: conf.getHaxdoc(@[node]))
  result.nimType = conf.toCxxType(node["type"])

  if "declarator" in node:
    result.name = cxxPair(getName(node["declarator"]))
    pointerWraps(node["declarator"], result.nimType)

  else:
    result.name = cxxPair("a" & $idx)

proc toCxxProc*(conf: WrapConf, node: CppNode): CxxProc =
  result = cxxProc(cxxPair(node["declarator"].getName()))
  result.returnType = conf.toCxxType(node["type"])

  if node[0].kind == cppTypeQualifier:
    result.returnType.flags.incl ctfConst

  pointerWraps(node["declarator"], result.returnType)

  let decl =
    if node["declarator"].kind == cppPointerDeclarator:
      node["declarator"].skipPointer()

    else:
      node["declarator"]

  for idx, arg in decl["parameters"]:
    result.arguments.add conf.toCxxArg(arg, idx)


proc toCxxField*(conf: WrapConf, node: CppNode): CxxField =
  assertKind(node, {cppFieldDeclaration})
  result = cxxField(
    cxxPair(getName(node["declarator"])),
    conf.toCxxType(node["type"]))

  pointerWraps(node["declarator"], result.nimType)

proc toCxxObject*(conf: WrapConf, node: CppNode): CxxObject =
  var decl: CxxNamePair
  if "name" in node:
    decl = cxxPair(node["name"].strVal())

  result = cxxObject(decl)

  case node.kind:
    of cppStructSpecifier:
      result.kind = cokStruct

    of cppUnionSpecifier:
      result.kind = cokUnion

    else:
      raise newImplementKindError(node)


  for field in node["body"]:
    case field.kind:
      of cppFieldDeclaration:
        result.mfields.add conf.toCxxField(field)

      of cppComment:
        result.mfields[^1].docComment.add field.strVal()

      else:
        raise newImplementKindError(field, field.treeRepr())



proc toCxx*(conf: WrapConf, node: CppNode): seq[CxxEntry] =
  case node.kind:
    of cppTranslationUnit,
       cppPreprocIfdef,
       cppPreprocIf,
       cppLinkageSpecification,
       cppDeclarationList,
       cppPreprocElse
         :
      for sub in node:
        result.add conf.toCxx(sub)

    of cppIdentifier,
       cppStringLiteral,
       cppPreprocInclude,
       cppParenthesizedExpression
         :
      discard

    of cppPreprocCall:
      discard

    of cppPreprocDef:
      if node.len < 2:
        discard

      else:
        result.add toCxxMacro(conf, node).box()

    of cppPreprocFunctionDef:
      result.add toCxxMacro(conf, node).box()

    of cppComment:
      discard
      # result.add toCxxComment(node.strVal)

    of cppEnumSpecifier:
      result.add toCxxEnum(conf, node).box()

    of cppTypeDefinition:
      if node.len == 1:
        case node[0].kind:
          of cppEnumSpecifier:
            result.add toCxxEnum(conf, node[0]).box()

          else:
            raise newImplementKindError(node[0])

      elif node.len == 2:
        case node[1].kind:
          of cppTypeIdentifier,
             cppPointerDeclarator,
             cppPrimitiveType
               :
            case node[0].kind:
              of cppSizedTypeSpecifier,
                 cppPrimitiveType
                   :
                var save = cxxAlias(
                  conf.toCxxType(node["type"]).toDecl(),
                  cxxTypeUse(node["declarator"].getName(), @[]))

                pointerWraps(node["declarator"], save.oldType)
                result.add save

              of cppStructSpecifier, cppUnionSpecifier:
                let struct = conf.toCxxObject(node[0])
                result.add cxxAlias(
                  struct.decl, conf.toCxxType(node["declarator"]))

              else:
                raise newImplementKindError(node[0], node.treeRepr())

          of cppFunctionDeclarator:
            result.add cxxAlias(
              conf.toCxxType(node["type"]).toDecl(),
              cxxTypeUse(node["declarator"].getName(), @[]))

          else:
            raise newImplementKindError(node, node.treeRepr())

      else:
        raise newImplementError(node.treeRepr())

    of cppDeclaration:
      case node["declarator"].skipPointer().kind:
        of cppFunctionDeclarator:
          result.add conf.toCxxProc(node)

        else:
          raise newImplementKindError(node[1], node.treeRepr())

    else:
      raise newImplementKindError(node, node.treeRepr(
        opts = hdisplay(maxlen = 10, maxdepth = 3)))

proc toCxx*(
  conf: WrapConf, file: AbsFile, expand: bool = false): seq[CxxEntry] =

  var str =
    if expand:
      file.getExpanded(conf.parseConf)

    else:
      file.readFile()

  result = conf.toCxx(parseCppString(addr str))


proc toCxx*(conf: WrapConf, str: string): seq[CxxEntry] =
  let node = parseCppString(unsafeAddr str)
  result = conf.toCxx(node)
