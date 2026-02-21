import 'dart:async';
import 'dart:convert';

import 'function.dart';

import "parameter.dart";
import 'http_buffer.dart';

export 'http_buffer.dart';

abstract class HttpClient {
  Duration timeout;
  HttpClient({this.timeout = const Duration(seconds: 30)});
  set prefix(String prefix);
  Map<String, String> getHeaders() => <String, String>{};
  int checkResult(RespData a, String url, Map<String, String> headers);
  Future<Response?>? sendReq(String url, ReqInfo params,
      String method); // RespData encodeData(String url, RespData resp);
  Map<String, dynamic> standardData(String url, dynamic jsonMap);
  void close() {}
}

/*
一个http,其返回值是不是json类型, 及底层框架是否转为json返回, 是由定义接口调用的人决定. 如果一个函数的返回值是RespData<a extends Parameter>则返回值是json类型;
*/
String buildUrl(String url, List<String> paramsters) {
  for (var i = 0; i < paramsters.length; i++) {
    url = url.replaceAll("{$i}", paramsters[i]);
  }
  return url;
}

abstract class BaseMethod {
  HttpClient client;
  BaseMethod({required this.client});
  Future<RespData<T>> sendReq<T>(
      String rawUrl, dynamic params, String method, bool slient) async {
    ReqInfo info;
    String url = rawUrl;
    if (params is RequestAbleParameter) {
      info = await params.getReqInfo();
      if (info.urlParameters != null) {
        url = buildUrl(rawUrl, info.urlParameters!);
      }
    } else {
      if (method == "GET") {
        if (params is JSONParameter) {
          params = params.toJson();
        }
        if (params is Map<String, dynamic>) {
          url = "$rawUrl?${makeQuery(params)}";
        }
        info = ReqInfo(contentType: URLENCODED);
      } else {
        info = ReqInfo(
            contentType: JSONTYPE,
            content: params == null ? "{}" : json.encode(params));
      }
    }
    var response = await client.sendReq(url, info, method);
    RespData<T> res;
    if (response == null) {
      //网络错误; //没有服务器返回结果;
      res = RespData(code: RespCode.NETWORK_ERROR);
    } else if (response.status == 200 &&
        (T != dynamic || response.contentType!.contains("json"))) {
      var jsonMap = json.decode(response.body!);
      //if (jsonMap["code"] == 0) {
      jsonMap = client.standardData(rawUrl, jsonMap); //将服务器返回的数据标准化;
      //}
      res = RespData.fromJson(jsonMap);
    } else {
      return RespData.raw(response);
    }
    if (!slient) {
      client.checkResult(res, url, response?.headers ?? <String, String>{});
    }
    return res;
  }

  Future<RespData<VT?>> getData<KT, VT>({
    dynamic data,
    bool slient = false,
    required String url,
    required Function(RespData resp) encodeDataFunction,
    ClassBuffer<KT, VT>? buffer,
    String method = "POST",
  }) async {
    //log.debug("come to getData");
    RespData<VT?> resp; //resp和返回类型不同,为什么不报告编译错误;
    if (buffer != null) {
      resp = await buffer.check(
        data: data,
        method: this,
        url: url,
        reqMethod: method,
        slient: slient,
        encodeDataFunction: encodeDataFunction,
      );
    } else {
      resp = await sendReq(url, data, method, slient);
      if (resp.code == 0) {
        encodeDataFunction(resp); //将json转换为对象;
      }
      resp.res = null;
    }
    return resp;
    //return this.dealData(resp);
  }

  //Future<RespData> dealData(Invocation invocation,RespData<dynamic> resp);
}

class HttpInfo {
  final String url;
  final dynamic buffer;
  const HttpInfo(this.url, [this.buffer]);
}
