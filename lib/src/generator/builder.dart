import 'dart:async';
import 'dart:io';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:path/path.dart' as p;
import 'package:source_gen/source_gen.dart';
import 'package:dart_style/dart_style.dart';
import 'package:http_method/src/generator/annotations.dart';

const String _myClientTemplate =
    """import 'package:http_method/http1_client.dart' as pl;
import 'package:http_method/http_method.dart';

class MyClient extends pl.HttpClientBase {
  MyClient() : super();
  @override
  int checkResult(RespData<dynamic> a, String url, Map<String, String> headers) {
    return 0;
  }
}
MyClient client = MyClient();

var bufferMap = <String, ClassBuffer<dynamic, dynamic>>{};
""";

const int _typeList = 1;

/// 网络接口生成器
class NetworkBuilder extends GeneratorForAnnotation<DataInterface> {
  // ignore: unused_field
  final _formatter =
      DartFormatter(languageVersion: DartFormatter.latestLanguageVersion);

  static final Set<String> _myClientChecked = <String>{};
  static final Set<String> _paginationControllerGenerated = <String>{};

  @override
  FutureOr<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    if (element is! ClassElement) {
      return "";
    }

    // 检查并复制 myclient.dart 模板文件（每个包只检查一次）
    final package = buildStep.inputId.package;
    if (!_myClientChecked.contains(package)) {
      _myClientChecked.add(package);
      await _ensureMyClientExists(buildStep, package);
    }

    final cls = element;
    final clsName = "${cls.name}Impl";
    final ifName = cls.name;
    var withMixin = annotation.read("mixins").stringValue;
    if (withMixin.isNotEmpty) {
      withMixin = "with $withMixin";
    }

    final methods = <String>[];

    for (var methodElement in cls.methods) {
      final methodData = _processMethod(methodElement);
      if (methodData != null) {
        methods.add(methodData.implementation);
      }
    }

    final clientValue = annotation.read("client").stringValue;
    final nameValue = annotation.read("name").stringValue;
    final client = clientValue.isNotEmpty ? clientValue : "client";
    final name = nameValue.isNotEmpty
        ? nameValue
        : "${cls.name![0].toLowerCase()}${cls.name!.substring(1)}Service";

    // Generate fetch methods for list responses
    final fetchMethods = <String>[];
    for (var methodElement in cls.methods) {
      final fetchMethod = _processFetchMethod(methodElement, cls, name);
      if (fetchMethod != null) {
        fetchMethods.add(fetchMethod);
      }
    }

    final buffer = StringBuffer();

    // Generate pagination controller interface and class only once per file
    final fileId = buildStep.inputId.path;
    if (!_paginationControllerGenerated.contains(fileId)) {
      _paginationControllerGenerated.add(fileId);
      buffer.writeln(_generatePaginationController());
      buffer.writeln();
    }

    buffer.writeln(
        "class $clsName extends BaseMethod $withMixin implements $ifName {");
    buffer.writeln("  $clsName({required super.client});");
    buffer.writeln();
    buffer.writeln("  ${methods.join("\n\n  ")}");
    buffer.writeln("}");
    buffer.writeln();
    buffer.writeln("var $name = $clsName(client: $client);");

    // Add fetch class if there are fetch methods
    if (fetchMethods.isNotEmpty) {
      final fetchClsName = "${cls.name}Fetch";
      buffer.writeln();
      buffer.writeln("class $fetchClsName {");
      buffer.writeln("  ${fetchMethods.join("\n\n  ")}");
      buffer.writeln("}");
    }

    return buffer.toString();
  }

  /// Returns the URL expression for generated code: variable name (e.g. loginUrl)
  /// when the annotation uses a constant reference, or quoted string when literal.
  String _getUrlExpression(
      MethodElement f, ConstantReader reader, TypeChecker reqConfigChecker) {
    final stringValue = reader.read("url").stringValue;
    final session = f.session;
    final library = f.library;

    final parsed = session?.getParsedLibraryByElement(library);
    if (parsed is! ParsedLibraryResult) return '"$stringValue"';

    final parsedLib = parsed;
    final declResult = parsedLib.getFragmentDeclaration(f.firstFragment);
    if (declResult == null) return '"$stringValue"';

    final methodNode = declResult.node;
    if (methodNode is! MethodDeclaration) return '"$stringValue"';

    for (final annotation in methodNode.metadata) {
      final name = annotation.name;
      final isReqConfig =
          name is SimpleIdentifier && name.name == 'ReqConfig' ||
              name is PrefixedIdentifier && name.identifier.name == 'ReqConfig';
      if (!isReqConfig) continue;

      final args = annotation.arguments?.arguments;
      if (args == null || args.isEmpty) break;

      final firstArg = args.first;
      if (firstArg is SimpleIdentifier || firstArg is PrefixedIdentifier) {
        final content = declResult.parsedUnit?.content;
        // content is the source code;
        if (content != null) {
          // get the variable name from the source code;
          return content.substring(firstArg.offset, firstArg.end);
        }
      }
      break;
    }
    return '"$stringValue"';
  }

  _MethodData? _processMethod(MethodElement f) {
    TypeChecker reqConfigChecker = TypeChecker.typeNamed(ReqConfig);
    final reqConfigAnnotation = reqConfigChecker.firstAnnotationOf(f);
    if (reqConfigAnnotation == null) return null;

    final reader = ConstantReader(reqConfigAnnotation);
    final urlExpr = _getUrlExpression(f, reader, reqConfigChecker);
    final returnType = f.returnType;
    if (returnType is! InterfaceType) return null;
    if (returnType.typeArguments.isEmpty) return null;

    final respType = returnType.typeArguments[0];
    if (respType is! InterfaceType) return null;
    if (respType.typeArguments.isEmpty) return null;

    final innerRespType = respType.typeArguments[0];
    final noDetailData =
        innerRespType is VoidType || innerRespType is DynamicType;

    String respName = "";
    String innerRespTypeString = "";
    String formatCode;

    if (noDetailData) {
      // Handle dynamic type - skip fromJson
      formatCode = "resp.obj = resp.res;";
    } else {
      // Handle non-dynamic types
      if (innerRespType is! InterfaceType) return null;
      innerRespTypeString =
          innerRespType.getDisplayString(withNullability: false);
      final innerRespTypeInterface = innerRespType;
      InterfaceType? realRespType;
      int? resultType;

      if (innerRespTypeInterface.typeArguments.isNotEmpty) {
        if (innerRespTypeInterface.isDartCoreList) {
          realRespType =
              innerRespTypeInterface.typeArguments[0] as InterfaceType;
          resultType = _typeList;
          // } else {
          //   var superclass = innerRespType.superclass;
          //   while (superclass != null && !superclass.isDartCoreObject) {
          //     if (superclass.getDisplayString(withNullability: false) ==
          //         "RSList<dynamic>") {
          //       realRespType = innerRespType.typeArguments[0] as InterfaceType;
          //       resultType = _typeRsList;
          //       break;
          //     }
          //     superclass = superclass.superclass;
          //   }
        }
      }

      realRespType ??= innerRespTypeInterface;
      respName = realRespType.getDisplayString(withNullability: false);

      String format = "";
      if (innerRespTypeInterface.getMethod("formatData") != null) {
        format = "a.formatData();";
      }

      switch (resultType) {
        case _typeList:
          formatCode = """
          resp.obj = (resp.res as List?)?.map((e) {
            var a = $respName.fromJson(e);
            $format
            return a;
          }).toList();""";
          break;
        // case _typeRsList:
        //   formatCode = """
        //     Map<String, dynamic> objs = resp.res;
        //     var b = (objs["rs"] as List?)?.map((e) {
        //       var a = $respName.fromJson(e);
        //       $format
        //       return a;
        //     }).toList();
        //     var a = ${innerRespType.getDisplayString(withNullability: false)}.fromJson(resp.res);
        //     a.rs = b;
        //     resp.obj = a;""";
        //   break;
        default:
          if (format.isEmpty) {
            formatCode = "resp.obj = $respName.fromJson(resp.res);";
          } else {
            formatCode = """
            resp.obj = $respName.fromJson(resp.res);
            var a = resp.obj;
            $format""";
          }
      }
    }

    final reqMethod = reader.peek("method")?.stringValue ?? "POST";
    final keyType = reader.peek("keyType")?.stringValue ?? "";
    final keyTypeString = keyType.isNotEmpty ? keyType : "int";

    final String methodDisplayString = f.toString();
    final List paramsList = (f.type as dynamic).parameters as List;

    final firstParam = paramsList.isNotEmpty ? paramsList[0].name : "null";
    final secondParam = paramsList.length > 1 ? (paramsList[1]).name : "false";

    final bufferString = noDetailData
        ? ""
        : "buffer: bufferMap[$urlExpr] as ClassBuffer<$keyTypeString, $innerRespTypeString>?,";
    final methodString = reqMethod != "POST" ? "method: \"$reqMethod\"," : "";
    final slientString = secondParam != "false" ? "slient: $secondParam," : "";

    final implementation = """
  @override
  $methodDisplayString=> getData(
        data: $firstParam,
        $slientString
        url: $urlExpr,
        $bufferString
        $methodString
        encodeDataFunction: (RespData resp) {
          $formatCode
        },
      );""";

    return _MethodData(implementation);
  }

  /// 确保 myclient.dart 文件存在，如果不存在则从模板复制
  Future<void> _ensureMyClientExists(
      BuildStep buildStep, String package) async {
    try {
      // 使用文件系统操作：检查目标文件是否存在
      // 获取源文件所在的目录（与 .g.dart 文件相同的目录）
      final sourcePath = buildStep.inputId.path;
      final sourceDir = p.dirname(sourcePath);
      final targetFile = File(p.join(sourceDir, 'myclient.dart'));

      // 如果文件已存在，直接返回
      if (await targetFile.exists()) {
        return;
      }

      // 尝试从 buildStep 读取模板文件
      String templateContent = _myClientTemplate;
      // 确保目录存在
      await targetFile.parent.create(recursive: true);

      // 复制模板内容到目标文件
      await targetFile.writeAsString(templateContent);
    } catch (e) {
      // 如果文件操作失败，忽略错误
      // 用户需要手动创建 myclient.dart
    }
  }

  /// Generate pagination controller interface and implementation
  String _generatePaginationController() {
    return """abstract class IPaginationController<T> {
  T get param;
  int get pageNum;
  int get pageSize;
  void setTotalCount(int total);
}
""";
  }

  /// Process a method to generate fetch method if it returns a list response
  String? _processFetchMethod(
      MethodElement f, ClassElement cls, String serviceInstanceName) {
    final returnType = f.returnType;
    if (returnType is! InterfaceType) return null;
    if (returnType.typeArguments.isEmpty) return null;

    final respType = returnType.typeArguments[0];
    if (respType is! InterfaceType) return null;
    if (respType.typeArguments.isEmpty) return null;

    var innerRespType = respType.typeArguments[0];
    if (innerRespType is! InterfaceType) return null;

    // 获取非空类型
    final innerElement = innerRespType.element;

    final listField = innerElement.getField('list');
    final totalField = innerElement.getField('total');

    if (listField == null || totalField == null) return null;

    final listFieldType = listField.type;
    if (listFieldType is! InterfaceType || listFieldType.typeArguments.isEmpty)
      return null;
    final listItemType = listFieldType.typeArguments[0];
    final parameters = (f.type as dynamic).parameters as List;
    final reqType = parameters.isNotEmpty ? parameters[0].type : null;
    if (reqType == null) return null;

    final methodName = f.name;

    return """
  static Future<List<${listItemType.getDisplayString(withNullability: false)}>> $methodName(IPaginationController<${reqType.getDisplayString(withNullability: false)}> controller) async {
    final baseParam = controller.param;
    baseParam.pageNum = controller.pageNum;
    baseParam.pageSize = controller.pageSize;

    final resp = await $serviceInstanceName.$methodName(baseParam);

    if (resp.code == RespCode.SUCCESS && resp.obj != null) {
      final obj = resp.obj!;
      controller.setTotalCount(obj.total);
      return obj.list;
    } else {
      throw Exception(resp.msg ?? "Failed to load data (code: \\\${resp.code})");
    }
  }""";
  }
}

class _MethodData {
  final String implementation;

  _MethodData(this.implementation);
}

/// Builder 工厂方法
Builder networkBuilder(BuilderOptions options) {
  return SharedPartBuilder(
    [NetworkBuilder()],
    'network',
  );
}

/// Parameters for generating implementation class
class _TableWidgetParams {
  final InterfaceType tItemType;
  final InterfaceType? tParamType;
  final bool useI18n;
  final String i18nFunction;
  final String fetchMethod;
  final List<String> columns;
  final List<String> skips;

  const _TableWidgetParams({
    required this.tItemType,
    this.tParamType,
    required this.useI18n,
    required this.i18nFunction,
    required this.fetchMethod,
    required this.columns,
    required this.skips,
  });
}

/// 自动生成 Widget 相关代码的 Builder
class WidgetBuilder extends GeneratorForAnnotation<TableWidget> {
  @override
  FutureOr<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) {
    if (element is! MixinElement) return "";

    final cls = element;
    // TableWidget is now only supported on mixin-style helpers.
    // We detect this by convention: the name ends with 'Mixin' and the
    // mixin (class) is constrained on TableContentWidget in its supertypes.
    if (cls.name == null || !cls.name!.endsWith('Mixin')) {
      return "";
    }

    // TableWidget always generates table widgets, no types parameter needed
    final useI18n = annotation.read("useI18n").boolValue;
    final i18nFunction = annotation.read("i18nFunction").stringValue;

    // Check for Type-based approach first (fetchClass + fetchMethodName)
    String fetchMethod = '';
    final fetchClassType = annotation.peek("fetchClass")?.typeValue;
    final fetchMethodName = annotation.peek("fetchMethod")?.stringValue ?? "";
    if (fetchClassType != null && fetchMethodName.isNotEmpty) {
      String className = '';
      // Type-based approach: fetchClass: OrgBizFetch, fetchMethodName: "listOrg"
      className = fetchClassType.getDisplayString(withNullability: false);
      fetchMethod = "${className}Fetch.$fetchMethodName";
    }

    // Read columns and skips parameters
    List<String> columns = const [];
    final columnsValue = annotation.peek("columns")?.listValue;
    if (columnsValue != null) {
      columns = columnsValue
          .map((e) => e.toStringValue() ?? "")
          .where((e) => e.isNotEmpty)
          .toList();
    }

    List<String> skips = const [];
    final skipsValue = annotation.peek("skips")?.listValue;
    if (skipsValue != null) {
      skips = skipsValue
          .map((e) => e.toStringValue() ?? "")
          .where((e) => e.isNotEmpty)
          .toList();
    }

    // Extract TableContentWidget<TItem, TParam> from constraints / supertypes
    InterfaceType? tItemType;
    InterfaceType? tParamType;

    // Scan all supertypes for TableContentWidget
    for (var type in cls.allSupertypes) {
      if (type.element.name == 'TableContentWidget' &&
          type.typeArguments.isNotEmpty) {
        final t = type.typeArguments[0];
        final element = t.element;
        if (element is InterfaceElement) {
          tItemType = element.thisType;
        }
        if (type.typeArguments.length > 1) {
          final paramType = type.typeArguments[1];
          tParamType = paramType as InterfaceType?;
        }
        break;
      }
    }

    if (tItemType == null) {
      return "";
    }

    // TableWidget always generates table widgets
    final params = _TableWidgetParams(
      tItemType: tItemType,
      tParamType: tParamType,
      useI18n: useI18n,
      i18nFunction: i18nFunction,
      fetchMethod: fetchMethod,
      columns: columns,
      skips: skips,
    );
    return _generateImplementationClass(cls, params);
  }

  String _generateImplementationClass(
      MixinElement cls, _TableWidgetParams params) {
    final buffer = StringBuffer();
    // Derive class name from mixin: strip trailing 'Mixin' if present
    final originalName = cls.name ?? '';
    final baseName = originalName.endsWith('Mixin')
        ? originalName.substring(0, originalName.length - 'Mixin'.length)
        : originalName;
    final implName = baseName;
    final tItemName = params.tItemType.getDisplayString(withNullability: false);
    final tParamName =
        params.tParamType?.getDisplayString(withNullability: false) ??
            'dynamic';

    // Mixins do not have constructors; always use a simple const constructor
    const constructorCall = "";

    final hasGenTableHeader =
        cls.methods.any((m) => m.name == 'genTableHeader' && !m.isAbstract);
    final hasGenTableData =
        cls.methods.any((m) => m.name == 'genTableData' && !m.isAbstract);
    final hasFetchData =
        cls.methods.any((m) => m.name == 'fetchData' && !m.isAbstract);

    final parts = _getWidgetParts(
        params.tItemType.element, params.useI18n, params.i18nFunction,
        methodProvider: cls,
        isItemContext: true,
        columns: params.columns,
        skips: params.skips);

    // Generate class that extends TableContentWidget and mixes in the annotated mixin
    buffer.writeln(
        "class $implName extends TableContentWidget<$tItemName, $tParamName> with ${cls.name} {");
    buffer.writeln("  const $implName({super.key})$constructorCall;");
    buffer.writeln();

    if (!hasFetchData && params.fetchMethod.isNotEmpty) {
      buffer.writeln("  @override");
      buffer.writeln(
          "  Future<List<$tItemName>> fetchData(PaginationController<$tParamName> controller) => ${params.fetchMethod}(controller);");
      buffer.writeln();
    }

    // TableWidget always generates table widgets
    if (!hasGenTableHeader) {
      buffer.writeln("  @override");
      buffer
          .writeln("  List<DataColumn> genTableHeader(BuildContext context) {");
      buffer.writeln("    return [");
      buffer.writeln("      ${parts.headers.join(",\n      ")}");
      buffer.writeln("    ];");
      buffer.writeln("  }");
      buffer.writeln();
    }

    if (!hasGenTableData) {
      buffer.writeln("  @override");
      buffer.writeln(
          "  List<DataCell> genTableData(BuildContext context, $tItemName item) {");
      buffer.writeln("    return [");
      buffer.writeln("      ${parts.cells.join(",\n      ")}");
      buffer.writeln("    ];");
      buffer.writeln("  }");
    }

    buffer.writeln("}");

    return buffer.toString();
  }

  _WidgetParts _getWidgetParts(
      InterfaceElement cls, bool useI18n, String i18nFunction,
      {required MixinElement methodProvider,
      required bool isItemContext,
      List<String> columns = const [],
      List<String> skips = const []}) {
    final headers = <String>[];
    final cells = <String>[];
    final detailRows = <String>[];

    // 1. if columns exist, just use it; 2. if not we init columns by class fields and skips; and gen the field map;
    List<String> columnNames;
    if (columns.isNotEmpty) {
      // Use specified columns
      columnNames = columns;
    } else {
      // Initialize columns by class fields and skips
      columnNames = [];
      final skipSet = <String>{'id'};
      if (skips.isNotEmpty) {
        skipSet.addAll(skips);
      }
      for (var field in cls.fields) {
        if (field.isStatic || field.isPrivate || field.name == null) continue;
        if (!skipSet.contains(field.name!)) {
          columnNames.add(field.name!);
        }
      }
    }

    // Generate field map for quick lookup
    final fieldMap = <String, FieldElement>{};
    for (var field in cls.fields) {
      if (!field.isStatic && !field.isPrivate && field.name != null) {
        fieldMap[field.name!] = field;
      }
    }

    // 3. for each column gen the headers & datacell;
    for (var columnName in columnNames) {
      // Generate header
      String columnLabel;
      if (useI18n) {
        columnLabel = "Text($i18nFunction('$columnName'))";
      } else {
        columnLabel = "const Text('$columnName')";
      }
      headers.add("DataColumn(label: $columnLabel)");

      // 4. for datacell;
      String valueExpr;
      final field = fieldMap[columnName];

      final capitalizedName = columnName.isEmpty
          ? ""
          : "${columnName[0].toUpperCase()}${columnName.substring(1)}";
      final customMethodName = "gen${capitalizedName}DataCell";
      if (field == null) {
        // - if column not in field, gen genXXXDataCell;
        valueExpr = "$customMethodName(context, item)";
      } else {
        // - else if genXXXDataCell exist call genXXXDataCell
        if (methodProvider.getMethod(customMethodName) != null) {
          valueExpr = "$customMethodName(context, item)";
        } else {
          // Generate DataCell with onTap
          final itemPrefix = isItemContext ? "item." : "";
          String textExpr = "Text($itemPrefix${field.name}.toString())";
          if (field.type.isDartCoreInt || field.type.isDartCoreDouble) {
            textExpr = "Center(child: $textExpr)";
          }
          // - else if onXXXTap, gen DataCell with it as onTap;
          final tapMethodName = "on${capitalizedName}Tap";
          if (methodProvider.getMethod(tapMethodName) != null) {
            valueExpr =
                "DataCell($textExpr, onTap: () => $tapMethodName(context, item))";
          } else {
            valueExpr = "DataCell($textExpr)";
          }
        }
      }

      cells.add(valueExpr);

      detailRows.add("""TableRow(children: [
        Padding(padding: const EdgeInsets.all(8.0), child: $columnLabel),
        Padding(padding: const EdgeInsets.all(8.0), child: const SizedBox.shrink()),
      ])""");
    }

    return _WidgetParts(headers, cells, detailRows);
  }
}

class _WidgetParts {
  final List<String> headers;
  final List<String> cells;
  final List<String> detailRows;
  _WidgetParts(this.headers, this.cells, this.detailRows);
}

/// WidgetBuilder 工厂方法
Builder widgetBuilder(BuilderOptions options) {
  return SharedPartBuilder(
    [WidgetBuilder()],
    'widget',
  );
}
