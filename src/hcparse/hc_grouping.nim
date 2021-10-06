import
  std/[options, hashes, sets, algorithm, sequtils, strutils, tables]

import
  ./interop_ir/wrap_store

import
  hmisc/types/[hgraph, colorstring],
  hmisc/hasts/graphviz_ast,
  hmisc/other/[oswrap, hpprint],
  hmisc/algo/halgorithm,
  hmisc/core/all

iterator mitems*[T](s1, s2: var seq[T]): var T =
  for it in mitems(s1): yield it
  for it in mitems(s2): yield it

iterator items*[T](s1, s2: seq[T]): T =
  for it in items(s1): yield it
  for it in items(s2): yield it

iterator pairs*[K, V](s1, s2: Table[K, V]): (K, V) =
  for it in pairs(s1): yield it
  for it in pairs(s2): yield it

type
  UsedSet {.requiresinit.} = ref object
    cursors: Table[CxxTypeDecl, HashSet[CxxTypeUse]]
    libs: Table[CxxLibImport, HashSet[CxxTypeUse]]

  UsedGroups = object
    inProcs: UsedSet
    inTypes: UsedSet

func mgetOrDefault*[K, V](table: var Table[K, V], key: K): var V =
  if key notin table:
    table[key] = default(V)

  return table[key]

proc registerUse*(ctype: CxxTypeUse, used: var UsedSet) =
  if isNil(ctype): return
  var used = used

  eachIdent(ctype) do (use: CxxTypeUse):
    let decl = use.getDecl()
    if decl.isSome():
      used.cursors.mgetOrDefault(decl.get()).incl use


proc registerUsedTypes*(genProc: CxxProc, used: var UsedSet) =
  for arg in genProc.arguments:
    registerUse(arg.getType(), used)

  registerUse(genProc.returnType, used)

proc registerUsedTypes*(entry: CxxEntry, used: var UsedGroups) =

  case entry.kind:
    of cekEnum, cekMacro, cekComment, cekTypeGroup, cekMacroGroup:
      discard

    of cekProc:
      registerUsedTypes(entry.cxxProc, used.inProcs)

    of cekObject:
      for field in entry.cxxObject.mfields:
        registerUse(field.getType(), used.inTypes)

      for meth in entry.cxxObject.methods:
        registerUsedTypes(meth, used.inProcs)

      for nested in entry.cxxObject.nested:
        registerUsedTypes(nested, used)

    of cekAlias:
      registerUse(entry.cxxAlias.baseType, used.inTypes)

    of cekPass, cekImport, cekForward, cekEmpty:
      discard

proc getUsedTypes*(file: CxxFile): UsedGroups =
  result = UsedGroups(inProcs: UsedSet(), inTypes: UsedSet())
  for e in file.entries:
    e.registerUsedTypes(result)

proc addImports(
    file: var CxxFile,
    usedGroup: UsedSet,
    ignoreImport: HashSet[CxxLibImport] = default(HashSet[CxxLibImport])
  ) =

  let save = file.savePath
  for typeCursor, _ in usedGroup.cursors:
    if typeCursor.hasImport():
      let usedLib = typeCursor.getImport()
      if usedLib notin ignoreImport:
        if save != usedLib:
          file.imports.incl usedLib

  for usedLib, _ in usedGroup.libs:
    if usedLib notin ignoreImport:
      if save != usedLib:
        file.imports.incl usedLib

proc addImports(
    graph: var HGraph[CxxLibImport, CxxTypeUse],
    file: CxxFile, used: UsedSet
  ) =
  ## Add imports from used set to file group

  block cursorBasedImportrs:
    # Library imports based on type definition location
    let user = file.savePath
    for typeCursor, typeSet in used.cursors:
      let dep = typeCursor.getImport()
      if user != dep: # Avoid self-imports (creates unnecessary
                      # self-loops in graphs)
        for item in typeSet:
          graph.addOrGetEdge(
            graph.addOrGetNode(user),
            graph.addOrGetNode(dep),
            item)

  block libraryOverrideImports:
    # Direct library overrides for imports
    let base = file.savePath
    for usedLib, typeSet in used.libs:
      for usedType in typeSet:
        graph.addOrGetEdge(
          graph.addOrGetNode(base),
          graph.addOrGetNode(usedLib),
          usedType)

proc regroupFiles*(wrapped: seq[CxxFile]): seq[CxxFile] =
  ## Construct new group of wrapped files based on the input. Group
  ## mutually recursive types in new temporary files and add needed imports
  ## and exports.

  var usedApis = UsedGroups(inProcs: UsedSet(), inTypes: UsedSet()) # Set of
  # cursors pointing to declarations for different types used in the file
  # entries (procedure argument and return, field, global variable types).

  var store: CxxTypeStore
  for file in wrapped:
    for entry in file.entries:
      registerUsedTypes(entry, usedApis)

      case entry.kind:
        of cekObject:
          store = entry.cxxObject.decl.store
          assertRef(store, $entry)

        of cekEnum:
          store = entry.cxxEnum.decl.store
          assertRef(store, $entry)

        of cekAlias:
          store = entry.cxxAlias.decl.store
          assertRef(store, $entry)

        else:
          discard

  if isNil(store):
    for decl, vals in usedApis.inTypes.cursors:
      assertRef decl.store, "Missing store ref for " & $decl
      store = decl.store
      break

  assertRef store

  var importGraph = newHGraph[CxxLibImport, CxxTypeUse]()
  # Type use graph - nodes represent files and `CxxTypeUse` is an edge
  # between two files. If one file uses type from another link is formed.

  block registerImports:
    var
      onlyTypes = newHGraph[CxxLibImport, CxxTypeUse]()
      onlyProcs = newHGraph[CxxLibImport, CxxTypeUse]()

    for file in wrapped:
      onlyTypes.addImports(file, usedApis.inTypes)
      onlyProcs.addImports(file, usedApis.inProcs)

      importGraph.addImports(file, usedApis.inTypes)
      importGraph.addImports(file, usedApis.inProcs)

    block:
      # Create debug graph of grouped imports and nodes
      onlyTypes.
        dotRepr(
          dotReprDollarNode[CxxLibImport],
          dotReprCollapseEdgesJoin[CxxTypeUse],
          clusters = onlyTypes.findCycles(ignoreSelf = true).
        mergeCycleSets().mapIt((it, ""))).withResIt do:
          it.rankdir = grdLeftRight
          it.toPng(getAppTempFile("onlyTypes.png"))

      onlyProcs.
        dotRepr(
          dotReprDollarNode[CxxLibImport],
          dotReprCollapseEdgesJoin[CxxTypeUse],
          clusters = onlyTypes.findCycles(ignoreSelf = true).
        mergeCycleSets().mapIt((it, ""))).withResIt do:
          it.rankdir = grdLeftRight
          it.toPng(getAppTempFile("onlyProcs.png"))

      importGraph.
        dotRepr(
          dotReprDollarNode[CxxLibImport],
          dotReprCollapseEdgesJoin[CxxTypeUse],
          clusters = onlyTypes.findCycles(ignoreSelf = true).
        mergeCycleSets().mapIt((it, ""))).withResIt do:
          it.rankdir = grdLeftRight
          it.toPng(getAppTempFile("importGraph.png"))

  let groups = importGraph.findCycles().mergeCycleSets()
  if groups.len == 0:
    # There is no mutually recursive type cycles in the passed files,
    # returning whole list unmodified.
    var mergedFiles = wrapped

    for file in mitems(mergedFiles):
      for entry in mitems(file.entries):
        # Drop forward type declarations that were defined in some other
        # file (can be imported).
        if entry of cekForward:
          let decl = store.getDecl(
            entry.cxxForward.decl.name.cxx,
            some file.savePath.library)

          # echov decl
          if decl.isSome():
            entry = cxxEmpty()

            if decl.get().typeImport.get() != file.savePath:
              file.imports.incl decl.get().typeImport.get()

    return mergedFiles

  let clusteredNodes = groups.mapIt(
    toHashSet(importGraph[it])).foldl(union(a, b))



  var fileMap: Table[CxxLibImport, CxxFile] # Mapping of the file import
                                            # location to the actual file
                                            # content

  for file in wrapped:
    fileMap[file.savePath] = file

  # Pass files that were not directly affected
  for file, wrapped in mpairs(fileMap):
    if file notin clusteredNodes:
      let used = wrapped.getUsedTypes()
      wrapped.addImports used.inProcs
      wrapped.addImports used.inTypes
      result.add wrapped


  # Process all groups that formed circular imports
  for group in groups:
    var
      mergedFiles: seq[CxxFile] = mapIt(group, fileMap[importGraph[it]])
      mergedLib: string = mergedFiles.mapIt(
        it.getLibrary()).toHashSet().toSeq()[0] # HACK - does not account
        # for type graphs that spans multiple packages. This is unlikely,
        # but possible in case of inter-*project* circular dependencies.

      generatedFile: CxxLibImport = cxxLibImport(mergedLib, @[
        mergedFiles.mapIt(it.getFilename()).sorted().join("_")])
        # Name of the generated file
        #
        # TODO allow overriding into someting more manageable. With large
        # libraries it would be possible to hit file name lenght limit on
        # windows and other oses that have this limitation

      ignoreImports: HashSet[CxxLibImport] = mapIt(
        group, importGraph[it]).toHashSet()

      mergedTypes: seq[CxxEntry]

    for file in mitems(mergedFiles):
      var recycle: seq[CxxEntry]
      for entry in mitems(file.entries):
        # Split all type declarations in the each file. Re-add procedure
        # declarations back, add type declarations to the global list.
        if entry of cekForward:
          if entry.cxxForward.decl.hasImport():
            entry = cxxEmpty()

          else:
            raise newImplementError("Promote type declaration")

        else:
          let (newDecl, extras) = entry.fragmentType()
          recycle.add extras
          mergedTypes.add newDecl

      file.entries.add recycle

      block getProcImports:
        let usedGroup = file.getUsedTypes()
        file.addImports(usedGroup.inProcs, ignoreImports)
        file.imports.incl generatedFile
        file.exports.incl generatedFile


    result.add mergedFiles

    block fillMergedFile:
      var merged =
        CxxFile(
          entries: mergedTypes,
          isGenerated: true,
          savePath: generatedFile)

      var typeImports: HashSet[CxxLibImport]
      block getTypeImports:
        let usedGroup = merged.getUsedTypes()
        for typeCursor, _ in usedGroup.inTypes.cursors:
          if typeCursor.hasImport():
            typeImports.incl typeCursor.getImport()

        for usedLib, _ in usedGroup.inTypes.libs:
          typeImports.incl usedLib

      let mergedLibs = group.mapIt(importGraph[it]).toHashSet()
      for imp in typeImports:
        if imp notin mergedLibs:
          merged.imports.incl imp
          merged.exports.incl imp

      result.add merged

  # cache.importGraph = importGraph

  # for file in mitems(result):
  #   file.addImport initNimImportSpec(true, @["std", "bitops"])
  #   file.addImport initNimImportSpec(true, @[
  #     "hmisc", "wrappers", "wraphelp"])

  #   file.exports.incl "wraphelp"
