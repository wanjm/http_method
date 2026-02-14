import 'dart:async';
import 'dart:convert';

import 'log.dart' as log;
import 'package:http/http.dart' as http;

import 'http_base.dart';
import 'parameter.dart';

abstract class HttpClientBase extends HttpClient {
  late String _prefix;
  HttpClientBase() : super();
  @override
  set prefix(String prefix) {
    _prefix = prefix;
  }

  @override
  Map<String, dynamic> standardData(String url,  jsonMap) {
    return jsonMap;
  }


  @override
  Future<Response?> sendReq(String url, ReqInfo params, String method) async {
    var body = params.content;
    var headers = getHeaders();
    headers["content-type"] = params.contentType!;
//    {"content-type": "application/json"};
    String requestLog =
        'PlasoHttp1Client@sendReq:\nRequest url: ${_prefix + url}\nRequest header: $headers';
    if (!params.contentType!.contains('multipart/form-data')) {
      requestLog += '\nRequest params: $body';
    }
    log.debug(requestLog, null);
    late http.Response response;
    if (method == "POST") {
      try {
        response = await http
            .post(Uri.parse(_prefix + url), headers: headers, body: body)
            .timeout(Duration(seconds: 30));
      } catch (e) {
        return null;
      }
    }

    if (method == "GET") {
      try {
        response = await http
            .get(Uri.parse(_prefix + url), headers: headers)
            .timeout(Duration(seconds: 30));
      } catch (e) {
        return null;
      }
    }

    var responseBody = response.body;
    if (response.headers['content-type']!.contains('application/json') &&
        !response.headers['content-type']!.contains('charset=utf-8')) {
      responseBody = Utf8Decoder().convert(response.bodyBytes);
    }
    log.debug(
        "PlasoHttp1Client@sendReq:\nResponse url: ${_prefix + url}\n  , response code: ${response.statusCode} , Response header: ${response.headers}\nResponse body: $responseBody",
        null);
    return Response(
        body: responseBody,
        bodyBytes: response.bodyBytes,
        contentType: response.headers["content-type"],
        status: response.statusCode,
        headers: response.headers);
  }
}
