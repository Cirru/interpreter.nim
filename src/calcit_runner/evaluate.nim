
import strutils
import strformat
import tables
import options
import sets

import cirru_parser
import cirru_edn
import ternary_tree

import ./types
import ./data
import ./data/virtual_list
import ./loader
import ./preprocess
import ./compiler_configs

import ./util/errors
import ./util/stack
import ./eval/arguments
import ./eval/expression
import ./codegen/special_calls

var programCode*: Table[string, FileSource]
var programData*: Table[string, ProgramFile]

proc hasNsAndDef(ns: string, def: string): bool =
  if not programCode.hasKey(ns):
    return false
  if not programCode[ns].defs.hasKey(def):
    return false
  return true

proc clearProgramDefs*(programData: var Table[string, ProgramFile], pkg: string): void =
  for ns, f in programData:
    if ns.startsWith(pkg):
      # echo "clearing: ", ns
      programData[ns].ns = none(Table[string, ImportInfo])
      programData[ns].defs.clear

  # mutual recursion
proc getEvaluatedByPath*(ns: string, def: string, scope: CirruDataScope): CirruData
proc loadImportDictByNs(ns: string): Table[string, ImportInfo]
proc preprocess*(code: CirruData, localDefs: Hashset[string], ns: string): CirruData
proc interpret*(xs: CirruData, scope: CirruDataScope, ns: string): CirruData

proc nativeEval(item: CirruData, interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  var code = interpret(item, scope, ns)
  code = preprocess(item, toHashset[string](scope.keys), ns)
  if not checkExprStructure(code):
    raiseEvalError("Expected cirru expr in eval(...)", code)
  echo "eval: ", $code
  interpret code, scope, ns

proc interpretSymbol(sym: CirruData, scope: CirruDataScope, ns: string): CirruData =
  # echo "interpret symbol: ", sym
  if sym.kind != crDataSymbol:
    raiseEvalError("Expects a symbol", sym)
  elif sym.resolved.kind == resolvedSyntax:
    raiseEvalError("not supposed to interpret a syntax symbol", sym)

  elif sym.resolved.kind == resolvedDef:
    let path = sym.resolved

    var v = programData[path.ns].defs[path.def]
    if v.kind == crDataThunk:
      while v.kind == crDataThunk:
        v = interpret(v.thunkCode[], v.thunkScope, v.thunkNs)
      programData[path.ns].defs[path.def] = v
    return v
  # else: kind=notResolved

  # TODO looped twice, could be faster
  if scope.contains(sym.symbolVal):
    return scope.loopGet(sym.symbolVal)

  let coreDefs = programData[coreNs].defs
  if coreDefs.contains(sym.symbolVal):
    return coreDefs[sym.symbolVal]

  let loadedSym = preprocess(sym, toHashset[string](@[]), ns)
  echo "[Warn] load unprocessed variable: ", sym
  if loadedSym.resolved.kind == resolvedDef:
    let path = loadedSym.resolved
    return programData[path.ns].defs[path.def]

  raiseEvalError(fmt"Symbol not initialized or recognized: {sym.symbolVal}", sym)

proc interpret*(xs: CirruData, scope: CirruDataScope, ns: string): CirruData =
  if ns == "":
    raiseEvalError("Expected non-empty ns", xs)

  case xs.kind
  of crDataNil, crDataString, crDataKeyword, crDataNumber, crDataBool, crDataProc, crDataFn, crDataTernary:
    return xs
  of crDataSymbol:
    return interpretSymbol(xs, scope, ns)
  else:
    discard

  if xs.len == 0:
    raiseEvalError("Cannot interpret empty expression", xs)

  # echo "\nInterpret: ", xs

  let head = xs[0]

  if head.kind == crDataSymbol and head.symbolVal == "eval":
    pushDefStack(StackInfo(ns: head.ns, def: head.symbolVal, code: xs, args: xs[1..^1]))
    if xs.len < 2:
      raiseEvalError("eval expects 1 argument", xs)
    let ret = nativeEval(xs[1], interpret, scope, ns)
    popDefStack()
    return ret

  let value = interpret(head, scope, ns)
  case value.kind
  of crDataString:
    raiseEvalError("String is not a function", xs)
  of crDataNumber:
    raiseEvalError("Number is not a function", xs)
  of crDataTernary:
    raiseEvalError("Ternary is not a function", xs)
  of crDataBool:
    raiseEvalError("Bool is not a function", xs)
  of crDataNil:
    raiseEvalError("nil is not a function", xs)

  of crDataProc:
    let f = value.procVal
    let args = spreadFuncArgs(xs[1..^1], interpret, scope, ns)

    # echo "HEAD: ", head, " ", xs
    # echo "calling: ", CirruData(kind: crDataList, listVal: initCrVirtualList(args)), " ", xs
    pushDefStack(head, CirruData(kind: crDataNil), args)
    let ret = f(args, interpret, scope, ns)
    popDefStack()
    return ret

  of crDataFn:
    # let fnPath = value.fnNs & "/" & value.fnName
    let args = spreadFuncArgs(xs[1..^1], interpret, scope, ns)

    # echo "HEAD: ", head, " ", xs
    pushDefStack(head, CirruData(kind: crDataList, listVal: initCrVirtualList(value.fnCode)), args)
    # echo "calling: ", CirruData(kind: crDataList, listVal: initCrVirtualList(args)), " ", xs
    let ret = evaluteFnData(value, args, interpret, ns)
    popDefStack()

    return ret

  of crDataKeyword:
    # keyword operator should be handled during macro expanding
    raiseEvalError("Dynamic keyword operator is not supported", xs)

  of crDataMap:
    if xs.len != 2: raiseEvalError("map function expects 1 argument", xs)
    let target = interpret(xs[1], scope, ns)
    return value.mapVal.loopGetDefault(target, CirruData(kind: crDataNil))

  of crDataMacro:
    echo "[warn] Found macros: ", xs
    raiseEvalError("Macros are supposed to be handled during preprocessing", xs)

  of crDataSyntax:
    let f = value.syntaxVal

    # pushDefStack(StackInfo(ns: head.ns, def: head.symbolVal, code: CirruData(kind: crDataNil), args: xs[1..^1]))
    let quoted = f(xs[1..^1], interpret, scope, ns)
    # popDefStack()
    return quoted

  else:
    raiseEvalError(fmt"Unknown head({head.kind}) for calling", xs)

proc placeholderFunc(args: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  echo "[Warn] placeholder function for preprocessing"
  return CirruData(kind: crDataNil)

proc preprocessSymbolByPath*(ns: string, def: string): void =
  if ns == "":
    raiseEvalError("Expected non-empty ns at " & def, @[])
  if not programData.hasKey(ns):
    var newFile = ProgramFile()
    programData[ns] = newFile

  if not programData[ns].defs.hasKey(def):
    if programCode.hasKey(ns).not:
      raise newException(ValueError, "No code for such ns: " & ns)
    if programCode[ns].defs.hasKey(def).not:
      raise newException(ValueError, "No such definition under " & ns & ": " & def)
    var code = programCode[ns].defs[def]
    programData[ns].defs[def] = CirruData(kind: crDataProc, procVal: placeholderFunc)
    pushDefStack(StackInfo(ns: ns, def: def, code: code, args: @[]))
    code = preprocess(code, toHashset[string](@[]), ns)
    popDefStack()
    # echo "setting: ", ns, "/", def
    # echo "processed code: ", code
    pushDefStack(StackInfo(ns: ns, def: def, code: code, args: @[]))
    if code.isADefinition():
      # definitions need to be initialized just before preprocessing
      programData[ns].defs[def] = interpret(code, CirruDataScope(), ns)
    else:
      var codeRef = new RefCirruData
      codeRef[] = code
      programData[ns].defs[def] = CirruData(
        kind: crDataThunk, thunkCode: codeRef, thunkNs: ns,
        thunkScope: CirruDataScope(),
      )
    popDefStack()

proc preprocessHelper(code: CirruData, localDefs: Hashset[string], ns: string): CirruData =
  preprocess(code, localDefs, ns)

proc preprocess*(code: CirruData, localDefs: Hashset[string], ns: string): CirruData =
  # echo "\nPreprocess: ", code
  case code.kind
  of crDataSymbol:
    if code.symbolVal.contains("/") and code.symbolVal[0] != '/' and code.symbolVal[^1] != '/':
      var sym = code
      let pieces = sym.symbolVal.split('/')
      if pieces.len != 2:
        raiseEvalError("Expects token in ns/def", sym)
      let nsPart = pieces[0]
      let defPart = pieces[1]
      let importDict = loadImportDictByNs(sym.ns)
      if importDict.hasKey(nsPart):
        let importTarget = importDict[nsPart]
        case importTarget.kind:
        of importNs:
          if importTarget.nsInStr: # js module, do not process inside current program
            sym.resolved = ResolvedPath(kind: resolvedDef, def: defPart, ns: importTarget.ns, nsInStr: true)
          else:
            preprocessSymbolByPath(importTarget.ns, defPart)
            sym.resolved = ResolvedPath(kind: resolvedDef, def: defPart, ns: importTarget.ns, nsInStr: false)
          return sym
        of importDef:
          raiseEvalError(fmt"Unknown ns ${sym.symbolVal}", sym)
      elif nsPart == "js":
        sym.resolved = ResolvedPath(kind: resolvedDef, def: defPart, ns: "js", nsInStr: false)
        return sym # js specific operators
      else:
        raiseEvalError("no such ns: " & nsPart, sym)
    elif code.symbolVal.len == 0:
      raiseEvalError("Empty token is not valid", code)
    elif code.symbolVal[0] == '.':
      var sym = code
      sym.resolved = ResolvedPath(kind: resolvedSyntax)
      return sym # only for code generation
    else:
      var sym = code

      if localDefs.contains(code.symbolVal):
        sym.resolved = ResolvedPath(kind: resolvedLocal)
        return sym
      elif code.symbolVal == "&" or code.symbolVal == "~" or code.symbolVal == "~@" or code.symbolVal == "eval":
        sym.resolved = ResolvedPath(kind: resolvedSyntax)
        return sym
      else:
        let coreDefs = programData[coreNs].defs
        if coreDefs.contains(sym.symbolVal):
          sym.resolved = ResolvedPath(kind: resolvedDef, ns: coreNs, def: sym.symbolVal, nsInStr: false)
          return sym
        elif hasNsAndDef(coreNs, sym.symbolVal):
          preprocessSymbolByPath(coreNs, sym.symbolVal)
          sym.resolved = ResolvedPath(kind: resolvedDef, ns: coreNs, def: sym.symbolVal, nsInStr: false)
          return sym

        elif hasNsAndDef(sym.ns, sym.symbolVal):
          preprocessSymbolByPath(sym.ns, sym.symbolVal)
          sym.resolved = ResolvedPath(kind: resolvedDef, ns: sym.ns, def: sym.symbolVal, nsInStr: false)
          return sym
        elif sym.ns.startsWith("calcit."):
          raiseEvalError(fmt"Cannot find symbol in core lib: {sym}", sym)
        else:
          let importDict = loadImportDictByNs(sym.ns)
          if importDict.hasKey(sym.symbolVal):
            let importTarget = importDict[sym.symbolVal]
            case importTarget.kind:
            of importDef:
              if importTarget.nsInStr:
                sym.resolved = ResolvedPath(kind: resolvedDef, ns: importTarget.ns, def: importTarget.def, nsInStr: true)
              else:
                preprocessSymbolByPath(importTarget.ns, importTarget.def)
                sym.resolved = ResolvedPath(kind: resolvedDef, ns: importTarget.ns, def: importTarget.def, nsInStr: false)
              return sym
            of importNs:
              raiseEvalError(fmt"Unknown def ${sym.symbolVal}", sym)

          # raiseEvalError(fmt"Unknown token {sym.symbolVal}", sym)
          if jsMode:
            if jsSyntaxProcs.contains(sym.symbolVal):
              discard
            else:
              echo "[Warn] symbol not resolved: ", sym, " in ", ns
          return sym

  of crDataList:
    if code.listVal.len == 0:
      return code

    var head = code.listVal[0]
    let originalValue = preprocess(head, localDefs, ns)
    var value = originalValue

    if value.kind == crDataSymbol and value.resolved.kind == resolvedDef:
      let path = value.resolved

      if path.ns == "js" or path.nsInStr:
        value = CirruData(kind: crDataProc, procVal: placeholderFunc) # a faked function
      else:
        value = programData[path.ns].defs[path.def]

        # force extracting thunk of functions
        if value.kind == crDataThunk:
          while value.kind == crDataThunk:
            value = interpret(value.thunkCode[], value.thunkScope, value.thunkNs)
          programData[path.ns].defs[path.def] = value

    # echo "run into: ", code, " ", value

    case value.kind
    of crDataProc, crDataFn:
      var xs = initCrVirtualList[CirruData](@[originalValue])
      for child in code.listVal.rest:
        xs = xs.append preprocess(child, localDefs, ns)
      return CirruData(kind: crDataList, listVal: xs)
    of crDataKeyword:
      if code.listVal.len != 2: raiseEvalError("Expected keyword call of length 2", code)
      var xs = initCrVirtualList[CirruData](@[
        CirruData(kind: crDataSymbol, symbolVal: "get", ns: ns),
        code.listVal[1],
        code.listVal[0],
      ])
      return preprocess(CirruData(kind: crDataList, listVal: xs), localDefs, ns)
    of crDataMacro:
      let xs = code[1..^1]
      pushDefStack(StackInfo(ns: head.ns, def: head.symbolVal, code: CirruData(kind: crDataList, listVal: initCrVirtualList(value.macroCode)), args: xs))

      let quoted = evaluteMacroData(value, xs, interpret, ns)
      popDefStack()
      # echo "\nMacro ->: ", code
      # echo   "expanded: ", quoted
      return preprocess(quoted, localDefs, ns)
    of crDataSyntax:
      if head.kind != crDataSymbol:
        raiseEvalError("Expected syntax head", code)
      head.resolved = ResolvedPath(kind: resolvedDef, ns: coreNs, def: head.symbolVal, nsInStr: false)
      let args = code[1..^1]
      case head.symbolVal
      of ";", "quote-replace":
        return code
      of "defn", "defmacro":
        return processDefn(head, args, localDefs, preprocessHelper, ns)
      of "&let":
        return processNativeLet(head, args, localDefs, preprocessHelper, ns)
      of "if", "assert", "do":
        return processAll(head, args, localDefs, preprocessHelper, ns)
      of "quote", "eval":
        return processQuote(head, args, localDefs, preprocessHelper, ns)
      of "defatom":
        return processDefAtom(head, args, localDefs, preprocessHelper, ns)
      else:
        raiseEvalError(fmt"Unknown syntax: ${head}", code)

      return code
    of crDataThunk:
      raiseEvalError("thunk should have been extracted", code)
    else:
      # could be dynamically passed functions
      var xs = initCrVirtualList[CirruData](@[originalValue])
      for child in code.listVal.rest:
        xs = xs.append preprocess(child, localDefs, ns)
      return CirruData(kind: crDataList, listVal: xs)
  of crDataNumber, crDataString, crDataNil, crDataBool, crDataKeyword, crDataTernary:
    return code
  else:
    # TODO supposed to be literals
    echo "[Warn] unexpected data during preprocess: " & $code
    return code

proc getEvaluatedByPath*(ns: string, def: string, scope: CirruDataScope): CirruData =
  if not programData.hasKey(ns):
    raiseEvalError(fmt"Not initialized during preprocessing: {ns}/{def}", CirruData(kind: crDataNil))

  if not programData[ns].defs.hasKey(def):
    var code = programCode[ns].defs[def]
    code = preprocess(code, toHashset[string](@[]), ns)
    raiseEvalError(fmt"Not initialized during preprocessing: {ns}/{def}", CirruData(kind: crDataNil))
    programData[ns].defs[def] = interpret(code, scope, ns)

  return programData[ns].defs[def]

proc loadImportDictByNs(ns: string): Table[string, ImportInfo] =
  let dict = programData[ns].ns
  if dict.isSome:
    return dict.get
  else:
    let v = extractNsInfo(programCode[ns].ns)
    programData[ns].ns = some(v)
    return v
