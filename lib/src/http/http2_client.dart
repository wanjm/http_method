import 'dart:convert';
import 'dart:io' hide HttpClient;

import 'log.dart' as log;
import 'package:http2/http2.dart';

import "http_base.dart";
import "parameter.dart";
// var uri = Uri.parse('https://dev.plaso.cn/custom/usr/doLogin');

abstract class HttpClientBase extends HttpClient {
  ClientTransportConnection? transport;
  late String host;
  late int port;
  Header mhpost = Header.ascii(':method', 'POST');
  late Header mhget;
  late Header scheme;
  late Header authority;
  Header ua = Header.ascii('user-agent', "Dart");
  Header ctjson = Header.ascii('content-type', JSONTYPE);
  // int? id;
  late String _prefix;
  //  Map<int, DateTime> wait;
  HttpClientBase({super.timeout});
  @override
  set prefix(String prefix) {
    var uri = Uri.parse(prefix);
    _prefix = uri.path;
    host = uri.host;
    port = uri.port;
    scheme = Header.ascii(':scheme', uri.scheme);
    authority = Header.ascii(':authority', uri.host);
  }

  Future<void> setUpTransport() async {
    if (transport != null) {
      if (transport!.isOpen) {
        //通过关闭网络的方式,可以检查到isOpen==false;
        log.debug("PlasoHttp2Client@setUpTransport: use exist transport", null);
        return;
      } else {
        log.error(
            "PlasoHttp2Client@setUpTransport: transport exist but not open",
            null);
      }
    }
    log.debug("PlasoHttp2Client@setUpTransport: set up transport", null);
    //todo 域名解析异常;
    try {
      transport = ClientTransportConnection.viaSocket(
          await SecureSocket.connect(host, port, supportedProtocols: ['h2']));
    } catch (e, stack) {
      log.error(
          "PlasoHttp2Client@setUpTransport: catch $e in setUpTransport: $stack",
          null);
      transport = null;
    }

    log.info(
        "PlasoHttp2Client@setUpTransport: set up transport finished", null);
  }

  List<Header> initHeader(String url, ReqInfo params) {
    var headersMap = getHeaders();
    List<Header> headers = [mhpost, scheme, authority, ua];
    if (params.contentType == JSONTYPE) {
      if (params.content is String) {
        headers.add(ctjson);
      }
    }
    for (var item in headersMap.entries) {
      headers.add(Header.ascii(item.key, item.value));
    }
    headers.add(Header.ascii(":path", _prefix + url));
    return headers;
  }

  @override
  Future<Response?> sendReq(String url, ReqInfo params, String method) async {
    //    var currentId = id++;
    var now = DateTime.now();
    //     I/flutter (12538): ERROR 2019-7-13_23:20:26.578 request not return more than 30 seconds;clear it
    // I/flutter (12538): DEBUG 2019-7-13_23:20:26.581 set up transport
    // I/flutter (12538): preapre finished
    // I/flutter (12538): DEBUG 2019-7-13_23:20:26.594 BoxConstraints(0.0<=w<=360.0, 0.0<=h<=730.0)
    // I/flutter (12538): DEBUG 2019-7-13_23:20:26.602 take care didChangedDependencies called, please check everything works
    // I/flutter (12538): DEBUG 2019-7-13_23:20:26.603 use controllor
    // I/flutter (12538): DEBUG 2019-7-13_23:20:26.603 physics is not null
    // I/flutter (12538): INFO 2019-7-13_23:21:11.654 call dispose in liveState
    // V/AudioManager(12538): playSoundEffect   effectType: 0
    // V/AudioManager(12538): querySoundEffectsEnabled...
    // I/flutter (12538): preapre finished
    // I/flutter (12538): DEBUG 2019-7-13_23:21:17.633 BoxConstraints(0.0<=w<=360.0, 0.0<=h<=730.0)
    // I/flutter (12538): DEBUG 2019-7-13_23:21:17.636 take care didChangedDependencies called, please check everything works
    // 此处添加的清除机制没有效果. 因为清除后, 后面重新setupTransport还是被hung住, 从上面的日志看,还是没有创建finished日志;
    // for (var i in wait.keys) {
    //   var datetime = wait[i];
    //   if (now.difference(datetime) > Duration(seconds: 30)) {
    //     if(transport!=null){
    //       transport.finish();
    //       transport.terminate();
    //     }
    //     transport = null;
    //     log.error("request not return more than 30 seconds;clear it");
    //     break;
    //   }
    // }
    // ;
    // if (transport == null && wait.length > 0) {
    //   wait.clear();
    // }
    // wait[currentId] = now;
    await setUpTransport();
    if (transport == null) {
      log.error("PlasoHttp2Client@sendReq: transport is null", null);
      return null;
    }
    var stream = transport!.makeRequest(initHeader(url, params));
    log.debug('PlasoHttp2Client@sendReq: will send $url', null);
    stream.sendData(Utf8Encoder().convert(params.content), endStream: true);
    List<int> messages = [];
    String? contentType;
    late String status;
    //await for will also throught exception need to be dealt
    //     Exception has occurred.
    // TransportConnectionException (HTTP/2 error: Connection error: Connection is being forcefully terminated. (errorCode: 10))
    // Exception has occurred.
    // StreamException (StreamException(stream id: 11): Remote end was telling us to stop. This stream was not processed and can therefore be retried (on a new connection).)
    try {
      log.debug('PlasoHttp2Client@sendReq: wait for response', null);
      await for (var message in stream.incomingMessages.timeout(timeout)) {
        if (message is HeadersStreamMessage) {
          for (var header in message.headers) {
            var name = utf8.decode(header.name);
            var a = DateTime.now();
            if (a.difference(now) > Duration(seconds: 10)) {
              log.debug(
                  "PlasoHttp2Client@sendReq: $name=${utf8.decode(header.value)}",
                  null);
            }
            if (name == "content-type") {
              contentType = utf8.decode(header.value);
            }
            if (name == ":status") {
              status = utf8.decode(header.value);
            }
          }
        } else if (message is DataStreamMessage) {
          messages.addAll(message.bytes);
          // Use [message.bytes] (but respect 'content-encoding' header)
        }
      }
    } catch (err, stack) {
      log.error("PlasoHttp2Client@sendReq: http2 error $err", null);
      log.error(stack, null);
      return null;
      // } finally {
      //   wait.remove(currentId);
    }
    //    {"content-type": "application/json"};
    // return Response(
    //     body: response.body,
    //     bodyBytes: response.bodyBytes,
    //     contentType: response.headers["content-type"]);
    //  }
    var resbody = Utf8Decoder().convert(messages);
    log.debug("PlasoHttp2Client@sendReq: response: $resbody", null);
    return Response(
        body: resbody, contentType: contentType, status: int.parse(status));
  }

  @override
  void close() {
    if (transport != null) {
      log.info("PlasoHttp2Client@close: call finished", null);
      transport!.finish();
    }
  }
}
