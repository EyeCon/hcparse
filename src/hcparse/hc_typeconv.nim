## Conversion of C types to nim

import ./read_libclang/[cxtypes, hc_types, cxcommon]
import hnimast

import
  hmisc/other/[hlogger],
  hmisc/types/colorstring,
  hmisc/algo/[hstring_algo, clformat],
  hmisc/core/all

import std/[
  strformat,
  sequtils,
  strutils,
  parseutils,
  tables
]

import ./processor/wrap_store


func add*(
    nimType: var NimType, genericParam: NimType | seq[NimType]) =

  assert not nimType.isComplex,
     "Cannot add generic parameters to a complex type"

  nimType.genParams.add genericParam



proc getTypeName*(cxtype: CXType, conf: WrapConf): string

proc toNimType*(
    cxtype: CXType, conf: WrapConf, cache: var WrapCache): NimType


proc fromElaboratedPType*(
    cxtype: CXType, conf: WrapConf, cache: var WrapCache): NimType =

  let decl = cxtype.getTypeDeclaration()
  if cxtype.getNumTemplateArguments() > 0:
    case decl.cxKind:
      of ckTypedefDecl, ckTypeAliasDecl, ckTypeAliasTemplateDecl:
        # WARNING `template <J, Q> using` is not handled
        result = newNimType(cxtype.getTypeName(conf), cxtype)

      of ckTypeDeclKinds:
        let params = cxtype.templateParams()
        result = newNimType(cxtype.getTypeName(conf), cxtype)
        for idx, parm in params:
          if parm.cxKind != tkInvalid:
            result.add parm.toNimType(conf, cache)

      else:
        conf.warn "Conversion from elaborated type: ", decl
        conf.debug "  ", decl.cxKind(), " in ", decl.getSpellingLocation()

  else:
    result = newNimType(getTypeName(cxtype, conf), cxtype)

proc dropPOD*(
    cxtype: CXType, conf: WrapConf, cache: var WrapCache): string =
  case cxtype.cxKind:
    of tkElaborated:
      cxtype.fromElaboratedPType(conf, cache).nimName

    of tkPointer:
      cxtype[].dropPOD(conf, cache)

    of tkTypedef:
      ($cxtype).dropPrefix("const ")

    else:
      ""

proc toCArg*(cursor: CXCursor, conf: WrapConf, cache: var WrapCache): CArg =
  var varname = $cursor
  if varname.len == 0:
    varname = "arg" & $cursor.cxType().dropPOD(conf, cache)

  let argType = cursor.cxType().toNimType(conf, cache)
  return initCArg(varname, argType)



proc toCName*(cursor: CXCursor): CName
proc toScopedIdent*(cursor: CXCursor): CScopedIdent =
  for elem in cursor:
    result.add toCName(elem)


proc fullScopedIdent*(
    conf: WrapConf,
    cxtype: CXType, filterInline: bool = true, withType: bool = true):
  CScopedIdent =

  for cursor in conf.getTypeNamespaces(cxtype, filterInline, withType):
    result.add toCName(cursor)

proc fullScopedIdent*(conf: WrapConf, nimType: NimType): CSCopedIdent =
  if nimType.fullIdent.isSome():
    nimType.fullIdent.get()

  else:
    conf.fullScopedIdent(nimType.cxType)



proc toCName*(cursor: CXCursor): CName =
  result = CName(cursor: cursor, isGenerated: false)
  for genParam in requiredGenericParams(cursor):
    # HACK add `genParam` explicitly. Was added because template type
    # parameters were ignored otherwise. Not sure if this is a general
    # enough solution, but it worked for now.
    let name = @[toCName(genParam)] & toScopedIdent(genParam)
    result.genParams.add name


proc toCName*(str: string, genp: seq[CScopedIdent] = @[]): CName =
  result = CName(name: str, isGenerated: true)
  result.genParams = genp

proc toScopedIdent*(name: seq[string]): CScopedIdent =
  for elem in name:
    result.add toCName(elem)

proc toScopedIdent*(sem: seq[CxCursor]): CSCopedIdent =
  for elem in sem:
    result.add toCName(elem)

proc toScopedIdent*(name: string): CScopedIdent =
  result.add toCName(name)

proc sameNoGeneric*(ident1, ident2: CScopedIdent): bool =
  result = ident1.len == ident2.len
  if result:
    for (a, b) in zip(ident1, ident2):
      if a.getName() != b.getName():
        return false

proc typeName*(ident: CScopedIdent): seq[string] =
  ident.mapIt($it.cursor)

proc namespacedName*(name: seq[CxCursor], conf: WrapConf): string =
  name.mapIt(getName(it)).join("::")

proc namespacedName*(decl: CxCursor, conf: WrapConf): string =
  ## Create /raw/ identifier from fully namespaces Cxx declaration entry.
  ##
  ## - EXAMPLE :: Given `namespace nsp { struct Str{}; }` and cursor that
  ##   points to the `Str` /declaration/ it should return
  assertKind(decl, ckTypeDeclKinds)
  conf.getSemanticNamespaces(decl).namespacedName(conf)

proc namespacedName*(cxtype: CxType, conf: WrapConf): string =
  ## Return fully qualified namespaced name for a type based on the type
  ## instance.
  conf.getTypeNamespaces(cxtype).namespacedName(conf)

proc newNimType*(
    conf: WrapConf,
    semspaces: seq[CxCursor], cxType: CxType): NimType =
  result = newNimType(semSpaces.namespacedName(conf), cxType)
  result.fullIdent = some toScopedIdent(semSpaces)

proc isComplexType*(
    conf: WrapConf, cxType: CxType, cache: var WrapCache): bool =

  let decl = cxType.getTypeDeclaration()
  if decl in cache.complexCache:
    return true

  result = false
  case cxType.cxKind():
    of tkTypedef:
      let parents = conf.getSemanticNamespaces(decl)

      if anyIt(parents, it.kind in ckTypeDeclKinds):
        cache.complexCache[decl] = none(NimType)
        return true

      for part in decl:
        if part.kind == ckTypeRef:
          let ptype = part.cxType()
          let complex = conf.isComplexType(ptype, cache)
          if complex:
            conf.notice cxType, "has complex type part", part

    of tkUnexposed:
      if decl.cxKind() notin ckTypeDeclKinds + { ckNoDeclFound }:
        conf.debug cxType, cxType.cxKind(), decl.cxKind()

    of tkPodKinds, tkRecord, tkEnum, tkElaborated,
       # Can't be complx
       tkLValueReference, tkPointer, tkRValueReference:
       # Pointee can be complex, but that's a problem for `toNimType`

      discard

    of tkDependentSizedArray:
      result = true

    of tkFunctionProto:
      if conf.isComplexType(cxType.getResultType(), cache):
        return true

      for arg in cxType.argTypes():
        if conf.isComplexType(arg, cache):
          return true

    of tkIncompleteArray:
      result = false

    else:
      conf.trace cxType, cxType.cxKind()

func newTemplateUndefined*(cxType: CxType): NimType =
  result = newNimType("CxxTemplateUndefined", cxType)
  result.isComplex = true

func newTemplateApproximate*(cxType: CxType, nimType: NimType): NimType =
  result = newNimType("CxxTemplateApproximate", @[nimType], cxType)
  result.isComplex = true

proc newComplexType*(
  conf: WrapConf, cxType: CxType, cache: var WrapCache): NimType =

  if notNil(conf.overrideComplex):
    let decl = cxType.getTypeDeclaration()
    if decl in cache.complexCache and
       cache.complexCache[decl].isSome():
      return cache.complexCache[decl].get()

    let override = conf.overrideComplex(cxType, conf, cache)
    if override.isSome():
      cache.complexCache[decl] = override
      return override.get()

  result = newTemplateUndefined(cxType)


proc defaultTypeParameter*(
  cursor: CxCursor, cache: var WrapCache, conf: WrapConf): Option[NimType] =
  # Clang represents default template type parameters using flat list that I
  # need to collect back into recursive structure again. The algorithm is pretty
  # similar to recursive descent parsing. Current implementation handles
  # only couple use cases right now - mainly `alloc = std::alloccator<char_t>`

  # Example of the template type parameters `_Alloc = std::allocator<_CharT>`
  #```
  # kind: TemplateTypeParameter _Alloc:
  #   +-> type: _Alloc
  #   +-> TemplateRef:
  #   |   +-> type: <invalid>
  #   |   +-> allocator
  #   +-> TypeRef:
  #       +-> type: _CharT
  #       +-> _CharT
  #```

  let params = toSeq(cursor)

  proc foldTypes(idx: var int, cache: var WrapCache): NimType =
    let param = params[idx]
    case param.kind:
      of ckTypeRef:
        result = toNimType(param.cxType(), conf, cache)
        inc idx

      of ckTemplateRef:
        let
          cxtype = param.cxType()
          def = param.getCursorDefinition()
          semspaces = conf.getSemanticNamespaces(def)

        result = conf.newNimType(semSpaces, cxtype)
        inc idx

        result.genParams.add foldTypes(idx, cache)

      else:
        raise newUnexpectedKindError(params[idx])

  var idx = 0
  return some foldTypes(idx, cache)

proc setParamsForType*(
    cache: var WrapCache, conf: WrapConf,
    ident: CScopedIdent, params: seq[NimType]
  ) =

  if params.len > 0:
    cache.paramsForType[ident.mapIt(getName(it))] = params

proc setParamsForType*(
    cache: var WrapCache, conf: WrapConf,
    ident: CScopedIdent, params: seq[CxCursor]
  ) =
  ## Set or update default template type parameters for type `ident`

  # This procedure is called multiple times and iteratively builds list of
  # actual default templated parameters based on different type
  # occurencies. This is necessary becase type /declaration/ is not
  # guaranteed to contain all the necessary information. Specific example -
  # `std::baisc_string`. It is defined as regular templated class with not
  # default parameters, which are specified in completely different file.

  # #+caption: `basic_string.h`
  # ```cpp
  # template<typename _CharT, typename _Traits, typename _Alloc>
  #   class basic_string
  # ```
  #
  # #+caption: `stringfwd.h`
  # ```cpp
  # template<typename _CharT, typename _Traits = char_traits<_CharT>,
  #        typename _Alloc = allocator<_CharT> >
  # class basic_string;
  # ```

  if params.len > 0:
    let key: seq[string] = ident.mapIt(getName(it))
    if key notin cache.paramsForType:
      cache.paramsForType[key] = @[]

    # Convenience helper to avoid writing `cache.paramsForType[key]`
    # all over the place.
    var list {.byaddr1.} = cache.paramsForType[key]

    for idx, param in params:
      var nimType = param.cxtype.toNimType(conf, cache)

      if list.high < idx:
        list.add NimType(kind: ctkIdent)

      if list[idx].defaultType.isNone():
        # Only assign if default template type parameter is none - current type
        # conversion is likely to have at least as much information (or more).
        list[idx] = nimType

      if param.len() > 0:
        var default = defaultTypeParameter(param, cache, conf)

        if default.isSome():
          list[idx].defaultType = default



proc replacePartials*(
    nimType: var NimType,
    partials: Table[string, NimType],
    conf: WrapConf) =

  ## Replace templated type names in `nimType` with corresponding ones from
  ## `partials`. This is used to create concrete instantiation of C++ template
  ## type with defaulted parameters

  proc aux(nimType: var NimType) =
    if nimType.kind == ctkIdent:
      if nimType.nimName in partials:
        nimType = partials[nimType.nimName]

      else:
        for subnode in mitems(nimType.genParams):
          aux(subnode)

  aux(nimType)

proc getParamsForType*(cache: WrapCache, name: seq[string]): seq[NimType] =
  if name in cache.paramsForType:
    result = cache.paramsForType[name]

proc getPartialParams*(
    name: seq[string], partialMax: int,
    conf: WrapConf, cache: var WrapCache,
    defaulted: bool = true
  ): seq[NimType] =

  if name in cache.paramsForType:
    let params = cache.paramsForType[name]
    for idx, param in params:
      if partialMax < idx:
        if param.defaultType.isNone() or not defaulted:
          # Even though procedure is callsed `getDefaultedPartial`, in
          # reality I have to substitute parameter without default values
          # as well. Example of why this is necessary:

          # ```cpp
          # basic_string
          # substr(size_type __pos = 0, size_type __n = npos) const
          # { return basic_string(*this,
          #     _M_check(__pos, "basic_string::substr"), __n); }
          # ```

          # Return type of this procedure does not have any explicit
          # generic parameters. Moreover - /first parameter/ does not
          # even have correct default value. So `genParams` naturally
          # returns empty list, and at the time type arrives here (this
          # procedure is called in the codegen stage mostly) we can't
          # reverse-track what went into arguments.

          result.add param
          result[^1].isParam = true

        else:
          result.add param.defaultType.get()


proc getPartialParams*(
    partial: NimType, conf: WrapConf, cache: var WrapCache,
    defaulted: bool = true
  ): seq[NimType] =
  ## Return defaulted generic parameters for partially instantiated
  ## template type

  if partial.fromCxType or partial.fullIdent.isSome():
    let name = conf.fullScopedIdent(partial).typeName()
    result = getPartialParams(
      name, partial.genParams.high, conf, cache, defaulted)



proc toNType*(
    nimType: NimType,
    conf: WrapConf, cache: var WrapCache,
    asResult: bool = false,
    noDefaulted: seq[CxCursor] = @[]
  ): NType[PNode] =


  proc aux(nimType: NimType, cache: var WrapCache): NType[PNode] =
    if isNil(nimType):
      result = newPType("void")

    else:
      case nimType.kind:
        of ctkPtr:
          result = newPtype("ptr", [aux(nimType.wrapped, cache)])

        of ctkIdent:
          assert nimType.nimName.len > 0
          result = newPType(nimType.nimName)
          for param in nimType.genParams:
            result.add aux(param, cache)


          var ignoreDefaulted = false
          if nimType.fromCxType and
             noDefaulted.len() > 0 and
             noDefaulted[0].kind in { ckClassTemplate }:

            # I'm not really sure about the necessary heuristics to correctly
            # determine conditions for `ignoreDefault`, so right now it is
            # implemented as an edge case based on the stdlib.
            #
            # `std::basic_string` has `.substr()` method that returns
            # `basic_string` - with /no/ template parameters specified. I
            # tried to find when it is possible to do this (completely omit
            # template type parameters, even including non-defaulted ones),
            # but could not find any conclusive answer. Anyway, the return
            # type is `basic_string`. When I try to convert it to `toNType`
            # it tries to substitute defaulted template types, namely
            # `std::char_traits<_CharT>` and allocator. But I actually need
            # it to use class's template type parameters.
            #
            # Right now I just collect all parent classes for a `GenProc` (in
            # `toNNode(GenProc)`), and pass it down here. If input `nimType`
            # that is passed here has the same /name/ (things are different
            # when they are cursors - `ckClassTemplate` and some other kind)
            # as `noDefaulted`, I consider it to be a valid reason to
            # `ignoreDefaulted`.
            #
            # This worked for `[[code:std::basic_string.substr(_, _, _)]]`,
            # but in general I don't think this is a fully correct check.

            let decl = nimType.cxType.getTypeDeclaration()
            ignoreDefaulted = $decl == $noDefaulted[0]

          for defaulted in nimType.getPartialParams(
            conf, cache,
            defaulted = not ignoreDefaulted
          ):

            result.add aux(defaulted, cache)

          if asResult and nimType.specialKind == ctskLValueRef:
            result = newPType("var", @[result])

        of ctkProc:
          result = newProcNType(
            nimType.arguments.mapIt((it.name, it.nimType.aux(cache))),
            nimType.returnType.aux(cache),
            newPPragma("cdecl"))

        else:
          raise newImplementKindError(nimType)


  if isNil(nimType):
    return newPType("void")

  else:
    var tmp = nimType
    conf.fixTypeName(tmp, conf, 0)
    return aux(tmp, cache)

proc getTypeName*(cxtype: CXType, conf: WrapConf): string =
  let curs = cxtype.getTypeDeclaration()
  case curs.cxKind:
    of ckTypedefDecl, ckTypeAliasDecl:
      return $curs.cxType()

    of ckTypeDeclKinds, ckTypeAliasTemplateDecl:
      result = getName(curs)

    else:
      conf.err $curs
      conf.err "Type name for ", curs.treeRepr(conf.unit)
      raiseAssert(
        &"Cannot convert cursor of kind {curs.cxKind} to type")

  result = namespacedName(cxtype, conf)

proc typeNameForScoped*(
    conf: WrapConf, ident: CScopedIdent, cache: var WrapCache): NimType =

  assert ident.len > 0
  var buf: seq[string]
  for name in ident:
    if name.getName() notin conf.collapsibleNamespaces:
      buf.add name.getName()

  assert buf.len > 0,
    &"Scoped indent '{ident}' got converted to zero-length nim type"

  result = newNimType(buf.join("::")).addIdent(ident)
  result.genParams = result.getPartialParams(
    conf, cache, defaulted = false)

  conf.fixTypeName(result, conf, 0)

proc isMutableRef*(cxtype: CXType): bool =
  case cxType.cxKind:
    of tkLValueReference, tkRValueReference:
      return not cxType.isConstQualified()


    of tkTypeDef:
      # TODO implement mutability checking
      let decl = cxtype.getTypeDeclaration()
      if decl.len == 1 and decl[0].cxKind == ckTypeRef:
        discard

    else:
      raiseAssert(&"#[ IMPLEMENT Is {cxtype.cxKind} a mutable ref? ]#")

proc fromCxxTypeName*(name: string): string =
  case name:
    of "long": "clong"
    of "int": "cint"
    of "unsigned long": "culong"
    else: ""

func mapPrimitiveNameImpl*(name: string):
    tuple[nim: string, pod: CxxPodTypeKind] =

  # REVIEW why is it necessary to return nim version of the name *and* pod
  # type kind at the same time, considering `hc_codegen.toNNode` for
  # `CxxTypeUse` does exactly the same?
  case name:
    of "short": ("cshort", cptI16)
    of "unsigned short": ("cushort", cptU16)

    of "int": ("cint", cptInt)
    of "unsigned", "unsigned int": ("cuint", cptUInt)

    of "long": ("clong", cptI32)
    of "unsigned long": ("culong", cptU32)

    of "long long": ("clonglong", cptI64)
    of "unsigned long long": ("culonglong", cptU64)



    of "void": ("void", cptVoid)

    of "char": ("char", cptChar)
    of "unsigned char": ("uint8", cptUChar)


    of "float": ("cfloat", cptFloat)
    of "bool": ("bool", cptBool)
    of "size_t": ("csize_t", cptSizeT)
    of "ssize_t": ("csize_t", cptSizeT)

    of "int16_t": ("int16", cptI16)
    of "int32_t": ("int32", cptI32)
    of "int64_t": ("int64", cptI64)

    of "uint8_t": ("uint8", cptU8)
    of "uint16_t": ("uint16", cptU16)
    of "uint32_t": ("uint32", cptU32)
    of "uint64_t": ("uint64", cptU64)
    # of tkBool:       ("bool")
    # of tkint:        ("cint")
    # of tkvoid:       ("void")
    # of tkuint:       ("cuint")
    # of tklonglong:   ("clonglong")
    # of tkulonglong:  ("culonglong")
    # of tkdouble:     ("cdouble")
    # of tkulong:      ("culong")
    # of tkuchar:      ("cuchar")
    # of tkchar16:     ("cchar16")
    # of tkchar32:     ("cchar32")
    # of tkwchar:      ("cwchar")
    # of tkchar_s:     ("cchar")
    # of tklong:       ("clong")
    # of tkushort:     ("cushort")
    # of tknullptr:    ("pointer") # warning c++ type is `nullptr_t`
    # of tkfloat:      ("cfloat")
    # of tklongdouble: ("clongdouble")
    # of tkshort:      ("cshort")
    # of tkschar:      ("cschar")

    else:
      raise newImplementKindError(name)


func mapPrimitiveName*(name: string): string =
  mapPrimitiveNameImpl(name).nim

func mapPrimitivePod*(name: string): CxxPodTypeKind =
  mapPrimitiveNameImpl(name).pod

proc toNimType*(
    cxtype: CXType, conf: WrapConf, cache: var WrapCache): NimType =
  ## Convert CXType to nim type. Due to differences in how mutability
  ## handled in nim and C it is not entirely possible to map `CXType` to
  ## `NimType` without losing this information. Instead `isMutable` is set
  ## in resulting type, indicating whether or not the type was mutable.
  ## Conversion is performed as follows
  ##
  ## - `T&` is considered mutable and mapped to `var T`
  ## - Any kind of pointer is mapped to immutable since it is not possible
  ##   infer this information from C type anyway.
  ## - Function prototype is mapped to `{.cdecl.}` proc type
  ## - 'special' types are mapped
  ##   - `char*` -> `cstring`
  ##   - `char**` -> `cstringArray`
  ##   - `void*` -> `pointer`
  ## - For C types with elaborated specifier (e.g. `enum E` instead of
  ##   simply `E`) specifiers are simply dropped.
  ##
  ## - TODO :: `const&&` parameters /could/ be mapped to `sink` annotations

  if conf.isComplexType(cxtype, cache):
    return conf.newComplexType(cxType, cache)

  var
    mutable: bool = false
    special: CTypeSpecialKind = ctskNone

  result = case cxtype.cxKind():
    of tkBool:       newNimType("bool",        cxtype)
    of tkInt:        newNimType("cint",        cxtype)
    of tkVoid:       newNimType("void",        cxtype)
    of tkUInt:       newNimType("cuint",       cxtype)
    of tkLongLong:   newNimType("clonglong",   cxtype)
    of tkULongLong:  newNimType("culonglong",  cxtype)
    of tkDouble:     newNimType("cdouble",     cxtype)
    of tkULong:      newNimType("culong",      cxtype)
    of tkUChar:      newNimType("cuchar",      cxtype)
    of tkChar16:     newNimType("cchar16",     cxtype)
    of tkChar32:     newNimType("cchar32",     cxtype)
    of tkWChar:      newNimType("cwchar",      cxtype)
    of tkChar_S:     newNimType("cchar",       cxtype)
    of tkLong:       newNimType("clong",       cxtype)
    of tkUShort:     newNimType("cushort",     cxtype)
    of tkNullPtr:    newNimType("pointer",     cxtype) # WARNING C++ type is `nullptr_t`
    of tkFloat:      newNimType("cfloat",      cxtype)
    of tkLongDouble: newNimType("clongdouble", cxtype)
    of tkShort:      newNimType("cshort",      cxtype)
    of tkSChar:      newNimType("cschar",      cxtype)
    of tkTypedef:
      mutable = cxType.isMutableRef()
      newNimType(($cxtype).dropPrefix("const "), cxtype) # XXXX typedef processing -

    of tkElaborated, tkRecord, tkEnum:
      # debug "From elaborated type"
      fromElaboratedPType(cxtype, conf, cache)

    of tkPointer:
      case cxtype[].cxkind:
        of tkChar_S:
          newNimType("cstring", cxtype)

        of tkPointer:
          if cxtype[][].cxKind() == tkChar_S:
            newNimType("cstringArray", cxtype)

          else:
            newNimType("ptr", [toNimType(cxtype[], conf, cache)], cxtype)

        of tkVoid:
          newNimType("pointer", cxtype)

        of tkFunctionProto:
          toNimType(cxtype[], conf, cache)

        else:
          newNimType("ptr", [toNimType(cxtype[], conf, cache)], cxtype)

    of tkConstantArray:
      newNimType(
        "ptr", [
          newNimType(
            "array", @[
              newNimType($cxtype.getNumElements(), cxtype.getElementType()),
              toNimType(cxtype.getElementType(), conf, cache)
            ], cxType)
        ], cxType)

    of tkIncompleteArray:
      # QUESTION maybe convert to `ptr UncheckedArray?` or add user-defined
      # callback for switching between different behaviors.
      newNimType("ptr", [toNimType(
        cxtype.getElementType(), conf, cache)], cxType)

    of tkFunctionProto:
      newNimType(
        cxtype.argTypes.mapIt(initCArg("", toNimType(it, conf, cache))),
        cxtype.getResultType().toNimType(conf, cache)
      )

    of tkLValueReference:
      # NOTE this implementation does not work as expected, becuase `const
      # T&` is not a const-qulified type.
      #
      # mutable = not cxType.isConstQualified()
      mutable = not startsWith($cxType, "const")
      special = ctskLValueRef

      toNimType(cxType[], conf, cache)

    of tkRValueReference: # WARNING I'm not 100% sure this is correct
                          # way to map rvalue references to nim type
                          # system.
      mutable = cxType.isMutableRef()
      special = ctskRValueRef
      toNimType(cxType[], conf, cache)

    of tkUnexposed:
      let strval = ($cxType).dropPrefix("const ") # WARNING
      let db = "string" in strval

      if strval.validCxxIdentifier():
        newNimType(strval, cxtype)

      else:
        let
          decl = cxtype.getTypeDeclaration()
          name = cxType.namespacedName(conf)
          typenameParts = toStrPart(@[
            "type-parameter", "typename type-parameter",
            "typename rebind<type-parameter",
            "typename"
          ])


        var res = newNimType(name, cxType)
        if decl.cxKind in ckTypeDeclKinds:
          # HACK list of necessary kinds is determined by trial and error,
          # I'm still not really sure what `tkUnexposed` actually
          # represents.
          for arg in cxType.templateParams():
            res.add toNimType(arg, conf, cache)
            res.genParams[^1].isParam = true

        elif startsWith($cxType, typenameParts):
          let unprefix = dropPrefix($cxType, typenameParts)
          if allIt(unprefix, it in {'0' .. '9', '-'}):
            res = newNimType("TYPE_PARAM " & unprefix, cxtype, true)

          else:
            res = newTemplateUndefined(cxType)

        else:
          res = newNimType("UNEXPOSED", cxtype, true)
          if decl.cxKind() notin {ckNoDeclFound}:
            conf.warn "No decl found for type"
            conf.logger.indented:
              conf.info cxtype.hshow()
              conf.debug decl.getSpellingLocation()
              conf.debug decl.cxKind()
              conf.debug decl.treeRepr()


        res

    of tkDependent:
      newNimType("DEPENDENT", cxType, true)

    of tkMemberPointer:
      # WARNING Member pointer
      newNimType("!!!", cxType, false)

    of tkDependentSizedArray:
      let cx = $cxtype
      let name = cx[cx.skipUntil('[') + 1 .. ^2].strip()
      newNimType("array", @[
        newNimType(name),
        toNimType(cxtype.getElementType(), conf, cache)
      ], cxType)

    else:
      conf.err "CANT CONVERT: ".toRed({styleItalic}),
        cxtype.kind, " ", ($cxtype).toGreen(), " ",
        cxtype[]

      newNimType("!!!", cxtype)

  result.isMutable = mutable
  result.specialKind = special



func fixTypeParams*(nt: var NimType, params: seq[NimType]) =
  func aux(nt: var NimType, idx: var int) =
    case nt.kind:
      of ctkAnonObject, ctkAnonEnum:
        raise newImplementKindError(nt)

      of ctkWrapKinds:
        aux(nt.wrapped, idx)

      of ctkArrayKinds:
        aux(nt.arrayElement, idx)

      of ctkStaticParam, ctkPod:
        discard

      of ctkIdent:
        if startsWith(nt.nimName, "TYPE_PARAM"):
          nt.nimName = params[idx].nimName
          inc idx

        for sub in mitems(nt.genParams):
          aux(sub, idx)

      of ctkProc:
        for arg in mitems(nt.arguments):
          aux(arg.nimType, idx)



  var idx: int
  aux(nt, idx)


func hasSpecial*(nt: NimType, special: seq[string]): bool =
  case nt.kind:
    of ctkAnonEnum, ctkAnonObject:
      raise newImplementKindError(nt)

    of ctkWrapKinds:
      nt.wrapped.hasSpecial(special)

    of ctkArrayKinds:
      nt.arrayElement.hasSpecial(special)

    of ctkStaticParam, ctkPod:
      false

    of ctkIdent:
      nt.nimName in special or
      nt.genParams.anyIt(it.hasSpecial(special))

    of ctkProc:
      nt.arguments.anyIt(it.nimType.hasSpecial(special))


func hasUnexposed*(nt: NimType): bool =
  nt.hasSpecial(@[ "UNEXPOSED", "DEPENDENT" ])


proc isEnum*(cxtype: CXType): bool =
  case cxtype.cxKind():
    of tkEnum:
      return true

    of tkElaborated:
      if cxtype.getTypeDeclaration().cxKind() in {ckEnumDecl}:
        return true

      else:
        return false

    else:
      return false

proc toInitCall*(
    cursor: CXCursor, conf: WrapConf, cache: var WrapCache): PNode =
  proc aux(
      cursor: CXCursor, ilist: bool, cache: var WrapCache,
      expected: Option[CxType] = none(CxType)
    ): PNode =
    case cursor.cxKind():
      of ckUnexposedExpr:
        if startsWith($cursor.cxType(), "std::initializer_list"):
          result = aux(cursor[0], true, cache)

        else:
          result = aux(cursor[0], ilist, cache, some cursor.cxType())

      of ckCallExpr:
        let str = "init" & $cursor.cxType()
        case cursor[0].cxKind():
          of ckUnexposedExpr, ckCallExpr, ckFunctionalCastExpr:
            result = aux(cursor[0], ilist, cache)

          of ckIntegerLiteral, ckNullPtrLiteralExpr:
            result = aux(cursor[0], ilist, cache)

          of ckTypeRef:
            # First found in `clang/Rewriter.h/getRangeSize()`
            result = newPCall(str)

          else:
            conf.err cursor[0].cxKind()
            conf.debug "\n" & cursor.treeRepr(conf.unit)
            conf.debug cursor.getSpellingLocation()

        if isNil(result):
          return

        if result.kind in nkTokenKinds:
          result = newPCall(str, result)

        elif result.kind == nkCall and
             result[0].getStrVal() != str:
          result = newPCall(str, result)

      of ckDeclRefExpr:
        if cursor.cxType().cxKind() == tkFunctionProto:
          result = newPCall($cursor)

        elif cursor.cxType().cxKind() == tkTypedef:
          conf.err "Found typedef used as default value"
          conf.debug cursor.getSpellingLocation()
          discard

        elif cursor.cxType().cxKind() == tkEnum:
          conf.err "Found enum value as default"
          conf.debug cursor.getSpellingLocation()
          discard

        else:
          conf.debug cursor.cxType().getTypeDeclaration().treeRepr()

          conf.debug cursor.getSpellingLocation()
          conf.debug cursor.treeRepr()
          raise newImplementKindError(cursor.cxType())

      of ckFunctionalCastExpr:
        result = aux(cursor[1], ilist, cache)

      of ckNullPtrLiteralExpr:
        result = newPLit(nil)

      of ckInitListExpr:
        if ilist:
          result = newPCall("cxxInitList")

        else:
          result = newPCall("init" & $cursor.cxType())

        for arg in cursor:
          result.add aux(arg, false, cache)

      of ckIntegerLiteral, ckCharacterLiteral, ckFloatingLiteral,
         ckStringLiteral:
        let tokens = cursor.tokenStrings(conf.unit)

        case cursor.cxKind():
          of ckIntegerLiteral:
            let i = newPLit(parseInt(tokens[0]))
            if expected.isSome():
              var expected = expected.get().toNimType(conf, cache)
              conf.fixTypeName(expected, conf, 0)
              result = newPCall(expected.nimName, i)

            else:
              result = newPCall("cint", i)

          of ckStringLiteral:
            result = newPCall("cstring", newPLit(tokens[0]))

          of ckCharacterLiteral:
            result = newPLit(tokens[0][1])

          of ckFloatingLiteral:
            result = newPLit(parseFloat(tokens[0]))

          else:
            discard

      of ckLambdaExpr:
        conf.err "FIXME implement conversion to call from lambda expr"
        discard

      of ckTypeRef:
        conf.err "FIXME implement conversion to call from type ref "
        discard

      of ckCStyleCastExpr:
        result = nnkCast.newPTree(
          cursor[0].cxType().toNimType(conf, cache).toNType(
            conf, cache).toNNode(),
          aux(cursor[1], ilist, cache))

      else:
        conf.err "Implement for kind", cursor.cxKind()
        conf.debug cursor.getSpellingLocation()
        conf.debug cursor.tokenStrings(conf.unit)

  return aux(cursor, false, cache)


proc setDefaultForArg*(
    arg: var CArg, cursor: CXCursor, conf: WrapConf, cache: var WrapCache) =
  ## Update default value for argument.
  ## - @arg{arg} :: Non-raw argument to update default for
  ## - @arg{cursor} :: original cursor for argument declaration
  ## - @arg{conf} :: Default wrap configuration

  if cursor.len == 2 and
     cursor[1].cxKind() in {ckUnexposedExpr, ckInitListExpr}:
    let default = toInitCall(cursor[1], conf, cache)
    if not isNil(default):
      arg.default = some(default)
