// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library generate_vm_service_lib_dart;

import 'package:markdown/markdown.dart';

import '../common/generate_common.dart';
import '../common/parser.dart';
import '../common/src_gen_common.dart';
import 'src_gen_dart.dart';

export 'src_gen_dart.dart' show DartGenerator;

Api api;

String _coerceRefType(String typeName) {
  if (typeName == 'Object') typeName = 'Obj';
  if (typeName == '@Object') typeName = 'ObjRef';
  if (typeName == 'Null') typeName = 'NullVal';
  if (typeName == '@Null') typeName = 'NullValRef';
  if (typeName == 'Function') typeName = 'Func';
  if (typeName == '@Function') typeName = 'FuncRef';

  if (typeName.startsWith('@')) typeName = typeName.substring(1) + 'Ref';

  if (typeName == 'string') typeName = 'String';
  if (typeName == 'map') typeName = 'Map';

  return typeName;
}

final String _headerCode = r'''
// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// This is a generated file.

/// A library to access the VM Service API.
///
/// The main entry-point for this library is the [VmService] class.
library vm_service_lib;

import 'dart:async';
import 'dart:convert' show base64, jsonDecode, jsonEncode, utf8;
import 'dart:typed_data';

import 'src/service_extension_registry.dart';

export 'src/service_extension_registry.dart' show ServiceExtensionRegistry;
''';

final String _implCode = r'''

  /// Call an arbitrary service protocol method. This allows clients to call
  /// methods not explicitly exposed by this library.
  Future<Response> callMethod(String method, {
    String isolateId,
    Map args
  }) {
    return callServiceExtension(method, isolateId: isolateId, args: args);
  }

  /// Invoke a specific service protocol extension method.
  ///
  /// See https://api.dartlang.org/stable/dart-developer/dart-developer-library.html.
  @override
  Future<Response> callServiceExtension(String method, {
    String isolateId,
    Map args
  }) {
    if (args == null && isolateId == null) {
      return _call(method);
    } else if (args == null) {
      return _call(method, {'isolateId': isolateId});
    } else {
      args = new Map.from(args);
      if (isolateId != null) {
        args['isolateId'] = isolateId;
      }
      return _call(method, args);
    }
  }

  Stream<String> get onSend => _onSend.stream;

  Stream<String> get onReceive => _onReceive.stream;

  void dispose() {
    _streamSub.cancel();
    _completers.values.forEach((c) => c.completeError('disposed'));
    if (_disposeHandler != null) _disposeHandler();
  }

  Future<T> _call<T>(String method, [Map args]) {
    String id = '${++_id}';
    Completer<T> completer = new Completer<T>();
    _completers[id] = completer;
    _methodCalls[id] = method;
    Map m = {'id': id, 'method': method};
    if (args != null) m['params'] = args;
    String message = jsonEncode(m);
    _onSend.add(message);
    _writeMessage(message);
    return completer.future;
  }

  /// Register a service for invocation.
  void registerServiceCallback(String service, ServiceCallback cb) {
    if (_services.containsKey(service)) {
      throw new Exception('Service \'${service}\' already registered');
    }
    _services[service] = cb;
  }

  void _processMessage(dynamic message) {
    // Expect a String, an int[], or a ByteData.

    if (message is String) {
      _processMessageStr(message);
    } else if (message is List<int>) {
      Uint8List list = new Uint8List.fromList(message);
      _processMessageByteData(new ByteData.view(list.buffer));
    } else if (message is ByteData) {
      _processMessageByteData(message);
    } else {
      _log.warning('unknown message type: ${message.runtimeType}');
    }
  }

  void _processMessageByteData(ByteData bytes) {
    int offset = 0;
    int metaSize = bytes.getUint32(offset + 4, Endian.big);
    offset += 8;
    String meta = utf8.decode(new Uint8List.view(
        bytes.buffer, bytes.offsetInBytes + offset, metaSize));
    offset += metaSize;
    ByteData data = new ByteData.view(bytes.buffer, bytes.offsetInBytes + offset,
        bytes.lengthInBytes - offset);
    dynamic map = jsonDecode(meta);
    if (map != null && map['method'] == 'streamNotify') {
      String streamId = map['params']['streamId'];
      Map event = map['params']['event'];
      event['_data'] = data;
      _getEventController(streamId).add(createServiceObject(event));
    }
  }

  void _processMessageStr(String message) {
    var json;
    try {
      _onReceive.add(message);

      json = jsonDecode(message);
    } catch (e, s) {
      _log.severe('unable to decode message: ${message}, ${e}\n${s}');
      return;
    }

    if (json.containsKey('method')) {
      if (json.containsKey('id')) {
        _processRequest(json);
      } else {
        _processNotification(json);
      }
    } else if(json.containsKey('id') && (
                json.containsKey('result') || json.containsKey('error')
              )) {
      _processResponse(json);
    }
    else {
     _log.severe('unknown message type: ${message}');
    }
  }

  void _processResponse(Map<String, dynamic> json) {
    Completer completer = _completers.remove(json['id']);
    String methodName = _methodCalls.remove(json['id']);

    if (completer == null) {
      _log.severe('unmatched request response: ${jsonEncode(json)}');
    } else if (json['error'] != null) {
      completer.completeError(RPCError.parse(methodName, json['error']));
    } else {
      Map<String, dynamic> result = json['result'] as Map<String, dynamic>;
      String type = result['type'];
      if (_typeFactories[type] == null) {
        completer.complete(Response.parse(result));
      } else {
        completer.complete(createServiceObject(result));
      }
    }
  }

  Future _processRequest(Map<String, dynamic> json) async {
    final Map m = await _routeRequest(json['method'], json['params']);
    m['id'] = json['id'];
    m['jsonrpc'] = '2.0';
    String message = jsonEncode(m);
    _onSend.add(message);
    _writeMessage(message);
  }

  Future _processNotification(Map<String, dynamic> json) async {
    final String method = json['method'];
    final Map params = json['params'];
    if (method == 'streamNotify') {
      String streamId = params['streamId'];
      _getEventController(streamId).add(createServiceObject(params['event']));
    } else {
      await _routeRequest(method, params);
    }
  }

  Future<Map> _routeRequest(String method, Map params) async{
    try {
      if (_services.containsKey(method)) {
        return await _services[method](params);
      }
      return {
        'error': {
          'code': -32601, // Method not found
          'message': 'Method not found \'$method\''
        }
      };
    } catch (e, st) {
      return {
        'error': {
          'code': -32000, // SERVER ERROR
          'message': 'Unexpected Server Error $e\n$st'
        }
      };
    }
  }
''';

final String _rpcError = r'''
typedef DisposeHandler = Future Function();

class RPCError {
  static RPCError parse(String callingMethod, dynamic json) {
    return new RPCError(callingMethod, json['code'], json['message'], json['data']);
  }

  final String callingMethod;
  final int code;
  final String message;
  final Map data;

  RPCError(this.callingMethod, this.code, this.message, [this.data]);

  String get details => data == null ? null : data['details'];

  String toString() {
    if (details == null) {
      return '${message} (${code}) from ${callingMethod}()';
    } else {
      return '${message} (${code}) from ${callingMethod}():\n${details}';
    }
  }
}

/// An `ExtensionData` is an arbitrary map that can have any contents.
class ExtensionData {
  static ExtensionData parse(Map json) =>
      json == null ? null : new ExtensionData._fromJson(json);

  final Map data;

  ExtensionData() : data = {};

  ExtensionData._fromJson(this.data);

  String toString() => '[ExtensionData ${data}]';
}

/// A logging handler you can pass to a [VmService] instance in order to get
/// notifications of non-fatal service protocol warnings and errors.
abstract class Log {
  /// Log a warning level message.
  void warning(String message);

  /// Log an error level message.
  void severe(String message);
}

class _NullLog implements Log {
  void warning(String message) {}
  void severe(String message) {}
}
''';

final _registerServiceImpl = '''
_serviceExtensionRegistry.registerExtension(params['service'], this);
response =  Success();''';

final _streamListenCaseImpl = '''
var id = params['streamId'];
if (_streamSubscriptions.containsKey(id)) {
  throw RPCError('streamListen', 103, 'Stream already subscribed', {
      'details': "The stream '\$id' is already subscribed",
    });
}

var stream = id == '_Service'
    ? _serviceExtensionRegistry.onExtensionEvent
    : _serviceImplementation.onEvent(id);
_streamSubscriptions[id] = stream.listen((e) {
  _responseSink.add({
    'jsonrpc': '2.0',
    'method': 'streamNotify',
    'params': {
      'streamId': id,
      'event': e.toJson(),
    },
  });
});
response = Success();''';

final _streamCancelCaseImpl = '''
var id = params['streamId'];
var existing = _streamSubscriptions.remove(id);
if (existing == null) {
  throw RPCError('streamCancel', 104, 'Stream not subscribed', {
      'details': "The stream '\$id' is not subscribed",
    });
}
await existing.cancel();
response = Success();''';

abstract class Member {
  String get name;

  String get docs => null;

  void generate(DartGenerator gen);

  bool get hasDocs => docs != null;

  String toString() => name;
}

class Api extends Member with ApiParseUtil {
  String serviceVersion;
  List<Method> methods = [];
  List<Enum> enums = [];
  List<Type> types = [];
  List<StreamCategory> streamCategories = [];

  void parse(List<Node> nodes) {
    serviceVersion = ApiParseUtil.parseVersionString(nodes);

    // Look for h3 nodes
    // the pre following it is the definition
    // the optional p following that is the documentation

    String h3Name;

    for (int i = 0; i < nodes.length; i++) {
      Node node = nodes[i];

      if (isPre(node) && h3Name != null) {
        String definition = textForCode(node);
        String docs = '';

        while (i + 1 < nodes.length &&
            (isPara(nodes[i + 1]) || isBlockquote(nodes[i + 1]))) {
          Element p = nodes[++i];
          String str = TextOutputVisitor.printText(p);
          if (!str.contains('|') && !str.contains('``')) {
            str = collapseWhitespace(str);
          }
          docs = '${docs}\n\n${str}';
        }

        docs = docs.trim();
        if (docs.isEmpty) docs = null;

        _parse(h3Name, definition, docs);
      } else if (isH3(node)) {
        h3Name = textForElement(node);
      } else if (isHeader(node)) {
        h3Name = null;
      }
    }

    for (Type type in types) {
      type.removeDuplicateFieldDefs();
    }

    Method streamListenMethod =
        methods.singleWhere((method) => method.name == 'streamListen');
    _parseStreamListenDocs(streamListenMethod.docs);
  }

  String get name => 'api';

  String get docs => null;

  void _parse(String name, String definition, [String docs]) {
    name = name.trim();
    definition = definition.trim();
    // clean markdown introduced changes
    definition = definition.replaceAll('&lt;', '<').replaceAll('&gt;', '>');
    if (docs != null) docs = docs.trim();

    if (definition.startsWith('class ')) {
      types.add(new Type(this, name, definition, docs));
    } else if (name.substring(0, 1).toLowerCase() == name.substring(0, 1)) {
      methods.add(new Method(name, definition, docs));
    } else if (definition.startsWith('enum ')) {
      enums.add(new Enum(name, definition, docs));
    } else {
      throw 'unexpected entity: ${name}, ${definition}';
    }
    // We merge Types and Enums with the same name.
    // The service.md file contains the public definition of Types and Enums.
    // The service_undocumented.md potentially contains overloaded definitions
    // of Types and Enums from the public definition with extra Type fields
    // or Enum values.
    _mergeTypes();
    _mergeEnums();
  }

  static String printNode(Node n) {
    if (n is Text) {
      return n.text;
    } else if (n is Element) {
      if (n.tag != 'h3') return n.tag;
      return '${n.tag}:[${n.children.map((c) => printNode(c)).join(', ')}]';
    } else {
      return '${n}';
    }
  }

  void generate(DartGenerator gen) {
    // Set default value for unspecified property
    setDefaultValue('Instance', 'valueAsStringIsTruncated', 'false');
    setDefaultValue('InstanceRef', 'valueAsStringIsTruncated', 'false');

    gen.out(_headerCode);
    gen.writeln("const String vmServiceVersion = '${serviceVersion}';");
    gen.writeln();
    gen.writeln('''
/// @optional
const String optional = 'optional';

/// @undocumented
const String undocumented = 'undocumented';

/// Decode a string in Base64 encoding into the equivalent non-encoded string.
/// This is useful for handling the results of the Stdout or Stderr events.
String decodeBase64(String str) => utf8.decode(base64.decode(str));

Object createServiceObject(dynamic json) {
  if (json == null) return null;

  if (json is List) {
    return json.map((e) => createServiceObject(e)).toList();
  } else if (json is Map) {
    String type = json['type'];
    if (_typeFactories[type] == null) {
      return null;
    } else {
      return _typeFactories[type](json);
    }
  } else {
    // Handle simple types.
    return json;
  }
}

dynamic _createSpecificObject(dynamic json, dynamic creator(Map<String, dynamic> map)) {
  if (json == null) return null;

  if (json is List) {
    return json.map((e) => creator(e)).toList();
  } else if (json is Map) {
    Map<String, dynamic> map = {};
    for (dynamic key in json.keys) {
      map[key as String] = json[key];
    }
    return creator(map);
  } else {
    // Handle simple types.
    return json;
  }
}

void _setIfNotNull(Map<String, Object> json, String key, Object value) {
  if (value == null) return;
  json[key] = value;
}

typedef ServiceCallback = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> params);

''');
    gen.writeln();
    gen.write('Map<String, Function> _typeFactories = {');
    types.forEach((Type type) {
      gen.writeln("'${type.rawName}': ${type.publicName}.parse,");
    });
    gen.writeln('};');
    gen.writeln();

    // The service interface, both servers and clients implement this.
    gen.writeStatement('''
/// A class representation of the Dart VM Service Protocol.
///
/// Both clients and servers should implement this interface.
abstract class VmServiceInterface {
  /// Returns the stream for a given stream id.
  ///
  /// This is not a part of the spec, but is needed for both the client and
  /// server to get access to the real event streams.
  Stream<Event> onEvent(String streamId);

  /// Handler for calling extra service extensions.
  Future<Response> callServiceExtension(String method, {String isolateId, Map args});
''');
    methods.forEach((m) {
      m.generateDefinition(gen);
      gen.write(';');
    });
    gen.write('}');
    gen.writeln();

    // The server class, takes a VmServiceInterface and delegates to it
    // automatically.
    gen.write('''
  /// A Dart VM Service Protocol connection that delegates requests to a
  /// [VmServiceInterface] implementation.
  ///
  /// One of these should be created for each client, but they should generally
  /// share the same [VmServiceInterface] and [ServiceExtensionRegistry]
  /// instances.
  class VmServerConnection {
    final Stream<Map<String, Object>> _requestStream;
    final StreamSink<Map<String, Object>> _responseSink;
    final ServiceExtensionRegistry _serviceExtensionRegistry;
    final VmServiceInterface _serviceImplementation;
    /// Used to create unique ids when acting as a proxy between clients.
    int _nextServiceRequestId = 0;

    /// Manages streams for `streamListen` and `streamCancel` requests.
    final _streamSubscriptions = <String, StreamSubscription>{};

    /// Completes when [_requestStream] is done.
    Future get done => _doneCompleter.future;
    final _doneCompleter = Completer<Null>();

    /// Pending service extension requests to this client by id.
    final _pendingServiceExtensionRequests =
        <String, Completer<Map<String, Object>>>{};

    VmServerConnection(
        this._requestStream, this._responseSink, this._serviceExtensionRegistry,
        this._serviceImplementation) {
      _requestStream.listen(_delegateRequest, onDone: _doneCompleter.complete);
      done.then(
          (_) => _streamSubscriptions.values.forEach((sub) => sub.cancel()));
    }

    /// Invoked when the current client has registered some extension, and
    /// another client sends an RPC request for that extension.
    ///
    /// We don't attempt to do any serialization or deserialization of the
    /// request or response in this case
    Future<Map<String, Object>> _forwardServiceExtensionRequest(
        Map<String, Object> request) {
      var originalId = request['id'];
      request = Map.of(request);
      // Modify the request ID to ensure we don't have conflicts between
      // multiple clients ids.
      var newId = '\${_nextServiceRequestId++}:\$originalId';
      request['id'] = newId;
      var responseCompleter = Completer<Map<String, Object>>();
      _pendingServiceExtensionRequests[newId] = responseCompleter;
      _responseSink.add(request);
      return responseCompleter.future;
    }

    void _delegateRequest(Map<String, Object> request) async {
      try {
        var id = request['id'] as String;
        // Check if this is actually a response to a pending request.
        if (_pendingServiceExtensionRequests.containsKey(id)) {
          // Restore the original request ID.
          var originalId = id.substring(id.indexOf(':') + 1);
          _pendingServiceExtensionRequests[id].complete(
              Map.of(request)..['id'] = originalId);
          return;
        }
        var method = request['method'] as String;
        if (method == null) {
          throw RPCError(null, -32600, 'Invalid Request', request);
        }
        var params = request['params'] as Map;
        Response response;

        switch(method) {
          case '_registerService':
            $_registerServiceImpl
            break;
    ''');
    methods.where((m) => !m.isUndocumented).forEach((m) {
      gen.writeln("case '${m.name}':");
      if (m.name == 'streamListen') {
        gen.writeln(_streamListenCaseImpl);
      } else if (m.name == 'streamCancel') {
        gen.writeln(_streamCancelCaseImpl);
      } else {
        gen.write("response = await _serviceImplementation.${m.name}(");
        // Positional args
        m.args.where((arg) => !arg.optional).forEach((arg) {
          gen.write("params['${arg.name}'], ");
        });
        // Optional named args
        var namedArgs = m.args.where((arg) => arg.optional);
        if (namedArgs.isNotEmpty) {
          namedArgs.forEach((arg) {
            if (arg.name == 'scope') {
              gen.writeln(
                  "${arg.name}: params['${arg.name}']?.cast<String, String>(), ");
            } else {
              gen.writeln("${arg.name}: params['${arg.name}'], ");
            }
          });
        }
        gen.writeln(");");
      }
      gen.writeln('break;');
    });
    // Handle service extensions
    gen.writeln('default:');
    gen.writeln('''
        var registeredClient = _serviceExtensionRegistry.clientFor(method);
        if (registeredClient != null) {
          // Check for any client which has registered this extension, if we
          // have one then delegate the request to that client.
          _responseSink.add(
              await registeredClient._forwardServiceExtensionRequest(request));
          // Bail out early in this case, we are just acting as a proxy and
          // never get a `Response` instance.
          return;
        } else if (method.startsWith('ext.')) {
          // Remaining methods with `ext.` are assumed to be registered via
          // dart:developer, which the service implementation handles.
          var args = params == null ? null : new Map.of(params);
          var isolateId = args?.remove('isolateId');
          response = await _serviceImplementation.callServiceExtension(method,
              isolateId: isolateId, args: args);
        } else {
          throw RPCError(method, -32601, 'Method not found', request);
        }
''');
    // Terminate the switch
    gen.writeln('}');

    // Handle null responses
    gen.write('''
      if (response == null) {
        throw StateError('Invalid null response from service');
      }
    ''');

    // Generate the json success response
    gen.write("""_responseSink.add({
  'jsonrpc': '2.0',
  'result': response.toJson(),
  'id': id,
});
""");

    // Close the try block, handle errors
    gen.write(r'''
      } catch (e, st) {
        var error = e is RPCError
            ? {'code': e.code, 'data': e.data, 'message': e.message}
            : {'code': -32603, 'message': '$e\n$st'};
        _responseSink.add({
          'jsonrpc': '2.0',
          'error': error,
          'id': request['id'],
        });
      }
''');

    // terminate the _delegateRequest method
    gen.write('}');
    gen.writeln();

    gen.write('}');
    gen.writeln();

    // The client side service implementation.
    gen.writeStatement('class VmService implements VmServiceInterface {');
    gen.writeStatement('StreamSubscription _streamSub;');
    gen.writeStatement('Function _writeMessage;');
    gen.writeStatement('int _id = 0;');
    gen.writeStatement('Map<String, Completer> _completers = {};');
    gen.writeStatement('Map<String, String> _methodCalls = {};');
    gen.writeStatement('Map<String, ServiceCallback> _services = {};');
    gen.writeStatement('Log _log;');
    gen.write('''

StreamController<String> _onSend = new StreamController.broadcast(sync: true);
StreamController<String> _onReceive = new StreamController.broadcast(sync: true);

Map<String, StreamController<Event>> _eventControllers = {};

StreamController<Event> _getEventController(String eventName) {
  StreamController<Event> controller = _eventControllers[eventName];
  if (controller == null) {
    controller = new StreamController.broadcast();
    _eventControllers[eventName] = controller;
  }
  return controller;
}

DisposeHandler _disposeHandler;

VmService(Stream<dynamic> /*String|List<int>*/ inStream, void writeMessage(String message), {
  Log log,
  DisposeHandler disposeHandler
}) {
  _streamSub = inStream.listen(_processMessage);
  _writeMessage = writeMessage;
  _log = log == null ? new _NullLog() : log;
  _disposeHandler = disposeHandler;
}

@override
Stream<Event> onEvent(String streamId) => _getEventController(streamId).stream;
''');

    // streamCategories
    streamCategories.forEach((s) => s.generate(gen));

    gen.writeln();
    methods.forEach((m) => m.generate(gen));
    gen.out(_implCode);
    gen.writeStatement('}');
    gen.writeln();
    gen.out(_rpcError);
    gen.writeln('// enums');
    enums.forEach((e) {
      if (e.name == 'EventKind') {
        _generateEventStream(gen);
      }
      e.generate(gen);
    });
    gen.writeln();
    gen.writeln('// types');
    types.where((t) => !t.skip).forEach((t) => t.generate(gen));
  }

  void _mergeTypes() {
    final Map<String, Type> map = <String, Type>{};
    for (Type t in types) {
      if (map.containsKey(t.name)) {
        map[t.name] = new Type.merge(map[t.name], t);
      } else {
        map[t.name] = t;
      }
    }
    types = map.values.toList();
  }

  void _mergeEnums() {
    final Map<String, Enum> map = <String, Enum>{};
    for (Enum e in enums) {
      if (map.containsKey(e.name)) {
        map[e.name] = new Enum.merge(map[e.name], e);
      } else {
        map[e.name] = e;
      }
    }
    enums = map.values.toList();
  }

  void generateAsserts(DartGenerator gen) {
    gen.out(r'''
// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// This is a generated file.

/// A library for asserting correct responses from the VM Service.

import 'package:vm_service_lib/vm_service_lib.dart' as vms;

dynamic assertNotNull(dynamic obj) {
  if (obj == null) throw 'assert failed';
  return obj;
}

bool assertBool(bool obj) {
  assertNotNull(obj);
  return obj;
}

int assertInt(int obj) {
  assertNotNull(obj);
  return obj;
}

double assertDouble(double obj) {
  assertNotNull(obj);
  return obj;
}

List<int> assertInts(List<int> list) {
  for (int elem in list) {
    assertInt(elem);
  }
  return list;
}

List<String> assertStrings(List<String> list) {
  for (String elem in list) {
    assertString(elem);
  }
  return list;
}

String assertString(String obj) {
  assertNotNull(obj);
  if (obj.isEmpty) throw 'expected non-zero length string';
  return obj;
}

vms.Success assertSuccess(vms.Success obj) {
  assertNotNull(obj);
  if (obj.type != 'Success') throw 'expected Success';
  return obj;
}

/// Assert PauseStart, PauseExit, PauseBreakpoint, PauseInterrupted,
/// PauseException, Resume, BreakpointAdded, BreakpointResolved,
/// BreakpointRemoved, and Inspect events.
vms.Event assertDebugEvent(vms.Event event) {
  assertEvent(event);
  if (event.kind == vms.EventKind.kPauseBreakpoint ||
      event.kind == vms.EventKind.kBreakpointAdded ||
      event.kind == vms.EventKind.kBreakpointRemoved ||
      event.kind == vms.EventKind.kBreakpointResolved) {
    assertBreakpoint(event.breakpoint);
  }
  if (event.kind == vms.EventKind.kPauseBreakpoint) {
    for (vms.Breakpoint elem in event.pauseBreakpoints) {
      assertBreakpoint(elem);
    }
  }
  if (event.kind == vms.EventKind.kPauseBreakpoint ||
      event.kind == vms.EventKind.kPauseInterrupted ||
      event.kind == vms.EventKind.kPauseException ||
      event.kind == vms.EventKind.kResume) {
    // For PauseInterrupted events, there will be no top frame if the isolate is
    // idle (waiting in the message loop).
    // For the Resume event, the top frame is provided at all times except for
    // the initial resume event that is delivered when an isolate begins
    // execution.
    if (event.topFrame != null ||
        (event.kind != vms.EventKind.kPauseInterrupted &&
            event.kind != vms.EventKind.kResume)) {
      assertFrame(event.topFrame);
    }
  }
  if (event.kind == vms.EventKind.kPauseException) {
    assertInstanceRef(event.exception);
  }
  if (event.kind == vms.EventKind.kPauseBreakpoint ||
      event.kind == vms.EventKind.kPauseInterrupted) {
    assertBool(event.atAsyncSuspension);
  }
  if (event.kind == vms.EventKind.kInspect) {
    assertInstanceRef(event.inspectee);
  }
  return event;
}

/// Assert IsolateStart, IsolateRunnable, IsolateExit, IsolateUpdate,
/// and ServiceExtensionAdded events.
vms.Event assertIsolateEvent(vms.Event event) {
  assertEvent(event);
  if (event.kind == vms.EventKind.kServiceExtensionAdded) {
    assertString(event.extensionRPC);
  }
  return event;
}

''');
    for (Enum e in enums) {
      e.generateAssert(gen);
    }
    for (Type type in types) {
      if (type.name == 'Success') continue;
      type.generateAssert(gen);
      if (type.name.endsWith('Ref') ||
          [
            'BoundVariable',
            'Breakpoint',
            'ContextElement',
            'Flag',
            'Frame',
            'LibraryDependency',
            'Message',
            'SourceReportRange',
            'ClassHeapStats',
            'CodeRegion',
            'ProfileFunction',
            'TimelineEvent',
          ].contains(type.name)) {
        type.generateListAssert(gen);
      }
    }
  }

  void setDefaultValue(String typeName, String fieldName, String defaultValue) {
    types
        .firstWhere((t) => t.name == typeName)
        .fields
        .firstWhere((f) => f.name == fieldName)
        .defaultValue = defaultValue;
  }

  bool isEnumName(String typeName) => enums.any((Enum e) => e.name == typeName);

  Type getType(String name) =>
      types.firstWhere((t) => t.name == name, orElse: () => null);

  void _parseStreamListenDocs(String docs) {
    Iterator<String> lines = docs.split('\n').map((l) => l.trim()).iterator;
    bool inStreamDef = false;

    while (lines.moveNext()) {
      final String line = lines.current;

      if (line.startsWith('streamId |')) {
        inStreamDef = true;
        lines.moveNext();
      } else if (inStreamDef) {
        if (line.isEmpty) {
          inStreamDef = false;
        } else {
          streamCategories.add(new StreamCategory(line));
        }
      }
    }
  }

  void _generateEventStream(DartGenerator gen) {
    gen.writeln();
    gen.writeDocs('An enum of available event streams.');
    gen.writeln('class EventStreams {');
    gen.writeln('EventStreams._();');
    gen.writeln();

    streamCategories.forEach((c) {
      gen.writeln("static const String k${c.name} = '${c.name}';");
    });

    gen.writeln('}');
  }
}

class StreamCategory {
  String _name;
  List<String> _events;

  StreamCategory(String line) {
    // Debug | PauseStart, PauseExit, ...
    _name = line.split('|')[0].trim();

    line = line.split('|')[1];
    _events = line.split(',').map((w) => w.trim()).toList();
  }

  String get name => _name;

  List<String> get events => _events;

  void generate(DartGenerator gen) {
    gen.writeln();
    gen.writeln('// ${events.join(', ')}');
    gen.writeln(
        "Stream<Event> get on${name}Event => _getEventController('$name').stream;");
  }

  String toString() => '$name: $events';
}

class Method extends Member {
  final String name;
  final String docs;

  MemberType returnType = new MemberType();
  List<MethodArg> args = [];

  Method(this.name, String definition, [this.docs]) {
    _parse(new Tokenizer(definition).tokenize());
  }

  bool get hasArgs => args.isNotEmpty;

  bool get hasOptionalArgs => args.any((MethodArg arg) => arg.optional);

  bool get isUndocumented => name.startsWith('_');

  String get publicName => isUndocumented ? name.substring(1) : name;

  void generate(DartGenerator gen) {
    generateDefinition(gen, withDocs: false, withOverrides: true);
    if (!hasArgs) {
      gen.writeStatement("=> _call('${name}');");
    } else if (hasOptionalArgs) {
      gen.writeStatement('{');
      gen.write('Map m = {');
      gen.write(args
          .where((MethodArg a) => !a.optional)
          .map((arg) => "'${arg.name}': ${arg.name}")
          .join(', '));
      gen.writeln('};');
      args.where((MethodArg a) => a.optional).forEach((MethodArg arg) {
        String valueRef = arg.name;
        // Special case for `getAllocationProfile`. We do not want to add these
        // params if they are false.
        if (name == 'getAllocationProfile') {
          gen.writeln("if (${arg.name} != null && ${arg.name}) {");
        } else {
          gen.writeln("if (${arg.name} != null) {");
        }
        gen.writeln("m['${arg.name}'] = ${valueRef};");
        gen.writeln("}");
      });
      gen.writeStatement("return _call('${name}', m);");
      gen.writeStatement('}');
    } else {
      gen.writeStatement('{');
      gen.write("return _call('${name}', {");
      gen.write(args.map((MethodArg arg) {
        return "'${arg.name}': ${arg.name}";
      }).join(', '));
      gen.writeStatement('});');
      gen.writeStatement('}');
    }
  }

  /// Writes the method definition without the body.
  ///
  /// Does not write an opening or closing bracket, or a trailing semicolon.
  ///
  /// If [withOverrides] is `true` then it will add an `@override` annotation
  /// before each method.
  void generateDefinition(DartGenerator gen,
      {bool withDocs = true, bool withOverrides = false}) {
    gen.writeln();
    if (withDocs && docs != null) {
      String _docs = docs == null ? '' : docs;
      if (returnType.isMultipleReturns) {
        _docs += '\n\nThe return value can be one of '
            '${joinLast(returnType.types.map((t) => '[${t}]'), ', ', ' or ')}.';
        _docs = _docs.trim();
      }
      if (_docs.isNotEmpty) gen.writeDocs(_docs);
    }
    if (isUndocumented) gen.writeln('@undocumented');
    if (withOverrides) gen.writeln('@override');
    gen.write('Future<${returnType.name}> ${publicName}(');
    bool startedOptional = false;
    gen.write(args.map((MethodArg arg) {
      String typeName;
      if (api.isEnumName(arg.type.name)) {
        if (arg.type.isArray) {
          typeName = typeName = '/*${arg.type}*/ List<String>';
        } else {
          typeName = '/*${arg.type}*/ String';
        }
      } else {
        typeName = arg.type.ref;
      }

      if (arg.optional && !startedOptional) {
        startedOptional = true;
        return '{${typeName} ${arg.name}';
      } else {
        return '${typeName} ${arg.name}';
      }
    }).join(', '));
    if (args.length >= 4) gen.write(',');
    if (startedOptional) gen.write('}');
    gen.write(') ');
  }

  void _parse(Token token) {
    new MethodParser(token).parseInto(this);
  }
}

class MemberType extends Member {
  List<TypeRef> types = [];

  MemberType();

  void parse(Parser parser) {
    // foo|bar[]|baz
    // (@Instance|Sentinel)[]
    bool loop = true;

    while (loop) {
      if (parser.consume('(')) {
        while (parser.peek().text != ')') {
          // @Instance | Sentinel
          parser.advance();
        }
        parser.consume(')');
        TypeRef ref = new TypeRef('dynamic');
        while (parser.consume('[')) {
          parser.expect(']');
          ref.arrayDepth++;
        }
        types.add(ref);
      } else {
        Token t = parser.expectName();
        TypeRef ref = new TypeRef(_coerceRefType(t.text));
        while (parser.consume('[')) {
          parser.expect(']');
          ref.arrayDepth++;
        }
        types.add(ref);
      }

      loop = parser.consume('|');
    }
  }

  String get name {
    if (types.isEmpty) return '';
    if (types.length == 1) return types.first.ref;
    return 'dynamic';
  }

  bool get isMultipleReturns => types.length > 1;

  bool get isSimple => types.length == 1 && types.first.isSimple;

  bool get isEnum => types.length == 1 && api.isEnumName(types.first.name);

  bool get isArray => types.length == 1 && types.first.isArray;

  void generate(DartGenerator gen) => gen.write(name);
}

class TypeRef {
  String name;
  int arrayDepth = 0;
  List<TypeRef> genericTypes;

  TypeRef(this.name);

  String get ref {
    if (arrayDepth == 2) {
      return 'List<List<${name}>>';
    } else if (arrayDepth == 1) {
      return 'List<${name}>';
    } else if (genericTypes != null) {
      return '$name<${genericTypes.join(', ')}>';
    } else {
      return name.startsWith('_') ? name.substring(1) : name;
    }
  }

  String get listTypeArg => arrayDepth == 2 ? 'List<$name>' : name;

  bool get isArray => arrayDepth > 0;

  bool get isSimple =>
      arrayDepth == 0 &&
      (name == 'int' ||
          name == 'num' ||
          name == 'String' ||
          name == 'bool' ||
          name == 'double');

  bool get isListTypeSimple =>
      arrayDepth == 1 &&
      (name == 'int' ||
          name == 'num' ||
          name == 'String' ||
          name == 'bool' ||
          name == 'double');

  String get namePlural => name.endsWith('y')
      ? name.substring(0, name.length - 1) + 'ies'
      : name + 's';

  String toString() => ref;
}

class MethodArg extends Member {
  final Method parent;
  TypeRef type;
  String name;
  bool optional = false;

  MethodArg(this.parent, this.type, this.name);

  // String get paramType => type;

  void generate(DartGenerator gen) {
    gen.write('${type.ref} ${name}');
  }
}

class Type extends Member {
  final Api parent;
  String rawName;
  String name;
  String superName;
  final String docs;
  List<TypeField> fields = [];

  Type(this.parent, String categoryName, String definition, [this.docs]) {
    _parse(new Tokenizer(definition).tokenize());
  }

  Type._(this.parent, this.rawName, this.name, this.superName, this.docs);

  factory Type.merge(Type t1, Type t2) {
    final Api parent = t1.parent;
    final String rawName = t1.rawName;
    final String name = t1.name;
    final String superName = t1.superName;
    final String docs = [t1.docs, t2.docs].where((e) => e != null).join('\n');
    final Map<String, TypeField> map = <String, TypeField>{};
    for (TypeField f in t2.fields.reversed) {
      map[f.name] = f;
    }
    // The official service.md is the default
    for (TypeField f in t1.fields.reversed) {
      map[f.name] = f;
    }

    final fields = map.values.toList().reversed.toList();

    return new Type._(parent, rawName, name, superName, docs)..fields = fields;
  }

  bool get isResponse {
    if (superName == null) return false;
    if (name == 'Response' || superName == 'Response') return true;
    return parent.getType(superName).isResponse;
  }

  bool get isRef => name.endsWith('Ref');

  bool get isUndocumented => name.startsWith('_');

  String get publicName => isUndocumented ? name.substring(1) : name;

  String get namePlural => name.endsWith('y')
      ? name.substring(0, name.length - 1) + 'ies'
      : name + 's';

  bool get supportsIdentity {
    if (fields.any((f) => f.name == 'id')) return true;
    return superName == null ? false : getSuper().supportsIdentity;
  }

  Type getSuper() => superName == null ? null : api.getType(superName);

  List<TypeField> getAllFields() {
    if (superName == null) return fields;

    List<TypeField> all = [];
    all.insertAll(0, fields);

    Type s = getSuper();
    while (s != null) {
      all.insertAll(0, s.fields);
      s = s.getSuper();
    }

    return all;
  }

  bool get skip => name == 'ExtensionData';

  void generate(DartGenerator gen) {
    gen.writeln();
    if (docs != null) gen.writeDocs(docs);
    if (isUndocumented) gen.writeln('@undocumented');
    gen.write('class ${publicName} ');
    if (superName != null) gen.write('extends ${superName} ');
    gen.writeln('{');
    gen.writeln('static ${publicName} parse(Map<String, dynamic> json) => '
        'json == null ? null : new ${publicName}._fromJson(json);');
    gen.writeln();

    if (name == 'Response') {
      gen.writeln('Map<String, dynamic> json;');
    }

    // fields
    fields.forEach((TypeField field) => field.generate(gen));
    gen.writeln();

    // ctors
    gen.writeln('${publicName}();');
    gen.writeln();

    String superCall = superName == null ? '' : ": super._fromJson(json) ";
    if (name == 'Response') {
      gen.write('${publicName}._fromJson(this.json)');
    } else {
      gen.write(
          '${publicName}._fromJson(Map<String, dynamic> json) ${superCall}');
    }

    if (fields.isEmpty) {
      gen.writeln(';');
    } else {
      gen.writeln('{');
    }

    fields.forEach((TypeField field) {
      if (field.type.isSimple || field.type.isEnum) {
        // Special case `AllocationProfile`.
        if (name == 'AllocationProfile' && field.type.name == 'int') {
          gen.write(
              "${field.generatableName} = json['${field.name}'] is String ? "
                  "int.parse(json['${field.name}']) : json['${field.name}']");
        } else {
          gen.write("${field.generatableName} = json['${field.name}']");
        }
        if (field.defaultValue != null) {
          gen.write(' ?? ${field.defaultValue}');
        }
        gen.writeln(';');
        // } else if (field.type.isEnum) {
        //   // Parse the enum.
        //   String enumTypeName = field.type.types.first.name;
        //   gen.writeln(
        //     "${field.generatableName} = _parse${enumTypeName}[json['${field.name}']];");
      } else if (name == 'Event' && field.name == 'extensionData') {
        // Special case `Event.extensionData`.
        gen.writeln(
            "extensionData = ExtensionData.parse(json['extensionData']);");
      } else if (name == 'Instance' && field.name == 'associations') {
        // Special case `Instance.associations`.
        gen.writeln("associations = json['associations'] == null "
            "? null : new List<MapAssociation>.from("
            "_createSpecificObject(json['associations'], MapAssociation.parse));");
      } else if (name == '_CpuProfile' && field.name == 'codes') {
        // Special case `_CpuProfile.codes`.
        gen.writeln("codes = new List<CodeRegion>.from("
            "_createSpecificObject(json['codes'], CodeRegion.parse));");
      } else if (name == '_CpuProfile' && field.name == 'functions') {
        // Special case `_CpuProfile.functions`.
        gen.writeln("functions = new List<ProfileFunction>.from("
            "_createSpecificObject(json['functions'], ProfileFunction.parse));");
      } else if (name == 'SourceReport' && field.name == 'ranges') {
        // Special case `SourceReport.ranges`.
        gen.writeln("ranges = new List<SourceReportRange>.from("
            "_createSpecificObject(json['ranges'], SourceReportRange.parse));");
      } else if (name == 'SourceReportRange' && field.name == 'coverage') {
        // Special case `SourceReportRange.coverage`.
        gen.writeln("coverage = _createSpecificObject("
            "json['coverage'], SourceReportCoverage.parse);");
      } else if (name == 'Library' && field.name == 'dependencies') {
        // Special case `Library.dependencies`.
        gen.writeln("dependencies = new List<LibraryDependency>.from("
            "_createSpecificObject(json['dependencies'], "
            "LibraryDependency.parse));");
      } else if (name == 'Script' && field.name == 'tokenPosTable') {
        // Special case `Script.tokenPosTable`.
        gen.write("tokenPosTable = ");
        if (field.optional) {
          gen.write("json['tokenPosTable'] == null ? null : ");
        }
        gen.writeln("new List<List<int>>.from(json['tokenPosTable'].map"
            "((dynamic list) => new List<int>.from(list)));");
      } else if (field.type.isArray) {
        TypeRef fieldType = field.type.types.first;
        String ref = "json['${field.name}']";
        if (field.optional) {
          if (fieldType.isListTypeSimple) {
            gen.writeln("${field.generatableName} = $ref == null ? null : "
                "new List<${fieldType.listTypeArg}>.from($ref);");
          } else {
            gen.writeln("${field.generatableName} = $ref == null ? null : "
                "new List<${fieldType.listTypeArg}>.from(createServiceObject($ref));");
          }
        } else {
          if (fieldType.isListTypeSimple) {
            // Special case `ClassHeapStats`. Pre 3.18, responses included keys
            // `new` and `old`. Post 3.18, these will be null.
            if (name == 'ClassHeapStats') {
              gen.writeln("${field.generatableName} = $ref == null ? null : "
                  "new List<${fieldType.listTypeArg}>.from($ref);");
            } else {
              gen.writeln("${field.generatableName} = "
                  "new List<${fieldType.listTypeArg}>.from($ref);");
            }
          } else {
            // Special case `InstanceSet`. Pre 3.20, instances were sent in a
            // field named 'samples' instead of 'instances'.
            if (name == 'InstanceSet') {
              gen.writeln("${field.generatableName} = "
                  "new List<${fieldType.listTypeArg}>.from(createServiceObject($ref ?? json['samples']));");
            } else {
              gen.writeln("${field.generatableName} = "
                  "new List<${fieldType.listTypeArg}>.from(createServiceObject($ref));");
            }
          }
        }
      } else {
        gen.writeln("${field.generatableName} = "
            "createServiceObject(json['${field.name}']);");
      }
    });
    if (fields.isNotEmpty) {
      gen.writeln('}');
    }
    gen.writeln();

    // toJson support, the base Response type is not supported
    if (name == 'Response') {
      gen.writeln('''
Map<String, dynamic> toJson() {
  var result = json == null ? <String, dynamic>{} : Map.of(json);
  result['type'] = type ?? 'Response';
  return result;
}''');
    } else {
      if (isResponse) {
        gen.writeln('@override');
      }
      gen.writeln('Map<String, dynamic> toJson() {');
      if (superName == null || superName == 'Response') {
        // The base Response type doesn't have a toJson
        gen.writeln('var json = <String, dynamic>{};');
      } else {
        gen.writeln('var json = super.toJson();');
      }

      // Only Response objects have a `type` field, as defined by protocol.
      if (isResponse) {
        // Overwrites "type" from the super class if we had one.
        gen.writeln("json['type'] = '$rawName';");
      }

      var requiredFields = fields.where((f) => !f.optional);
      if (requiredFields.isNotEmpty) {
        gen.writeln('json.addAll({');
        requiredFields.forEach((TypeField field) {
          gen.write("'${field.name}': ");
          generateSerializedFieldAccess(field, gen);
          gen.writeln(',');
        });
        gen.writeln('});');
      }

      var optionalFields = fields.where((f) => f.optional);
      optionalFields.forEach((TypeField field) {
        gen.write("_setIfNotNull(json, '${field.name}', ");
        generateSerializedFieldAccess(field, gen);
        gen.writeln(');');
      });
      gen.writeln('return json;');
      gen.writeln('}');
      gen.writeln();
    }

    // equals and hashCode
    if (supportsIdentity) {
      gen.writeStatement('int get hashCode => id.hashCode;');
      gen.writeln();

      gen.writeStatement(
          'operator==(other) => other is ${name} && id == other.id;');
      gen.writeln();
    }

    // toString()
    Iterable<TypeField> toStringFields =
        getAllFields().where((f) => !f.optional);
    if (toStringFields.length <= 7) {
      String properties = toStringFields
          .map(
              (TypeField f) => "${f.generatableName}: \${${f.generatableName}}")
          .join(', ');
      if (properties.length > 60) {
        int index = properties.indexOf(', ', 55);
        if (index != -1) {
          properties = properties.substring(0, index + 2) +
              "' //\n'" +
              properties.substring(index + 2);
        }
        gen.writeln("String toString() => '[${name} ' //\n'${properties}]';");
      } else {
        gen.writeln("String toString() => '[${name} ${properties}]';");
      }
    } else {
      gen.writeln("String toString() => '[${name}]';");
    }

    gen.writeln('}');
  }

  // Writes the code to retrieve the serialized value of a field.
  void generateSerializedFieldAccess(TypeField field, DartGenerator gen) {
    var nullAware = field.optional ? '?' : '';
    if (field.type.isSimple || field.type.isEnum) {
      gen.write('${field.generatableName}');
      if (field.defaultValue != null) {
        gen.write(' ?? ${field.defaultValue}');
      }
    } else if (name == 'Event' && field.name == 'extensionData') {
      // Special case `Event.extensionData`.
      gen.writeln('extensionData$nullAware.data');
    } else if (field.type.isArray) {
      gen.write('${field.generatableName}$nullAware.map((f) => f');
      // Special case `tokenPosTable` which is a List<List<int>>.
      if (field.name == 'tokenPosTable') {
        gen.write('$nullAware.toList()');
      } else if (!field.type.types.first.isListTypeSimple) {
        gen.write('$nullAware.toJson()');
      }
      gen.write(')$nullAware.toList()');
    } else {
      gen.write('${field.generatableName}$nullAware.toJson()');
    }
  }

  void generateAssert(DartGenerator gen) {
    gen.writeln('vms.${publicName} assert${name}(vms.${publicName} obj) {');
    gen.writeln('assertNotNull(obj);');
    for (TypeField field in getAllFields()) {
      if (!field.optional) {
        MemberType type = field.type;
        if (type.isArray) {
          TypeRef arrayType = type.types.first;
          if (arrayType.arrayDepth == 1) {
            String assertMethodName = 'assert' +
                arrayType.name.substring(0, 1).toUpperCase() +
                arrayType.namePlural.substring(1);
            gen.writeln('$assertMethodName(obj.${field.generatableName});');
          } else {
            gen.writeln(
                '// assert obj.${field.generatableName} is ${type.name}');
          }
        } else if (type.isMultipleReturns) {
          bool first = true;
          for (TypeRef typeRef in type.types) {
            if (!first) gen.write('} else ');
            first = false;
            gen.writeln(
                'if (obj.${field.generatableName} is vms.${typeRef.name}) {');
            String assertMethodName = 'assert' +
                typeRef.name.substring(0, 1).toUpperCase() +
                typeRef.name.substring(1);
            gen.writeln('$assertMethodName(obj.${field.generatableName});');
          }
          gen.writeln('} else {');
          gen.writeln(
              'throw "Unexpected value: \${obj.${field.generatableName}}";');
          gen.writeln('}');
        } else {
          String assertMethodName = 'assert' +
              type.name.substring(0, 1).toUpperCase() +
              type.name.substring(1);
          gen.writeln('$assertMethodName(obj.${field.generatableName});');
        }
      }
    }
    gen.writeln('return obj;');
    gen.writeln('}');
    gen.writeln('');
  }

  void generateListAssert(DartGenerator gen) {
    gen.writeln('List<vms.${name}> '
        'assert${namePlural}(List<vms.${name}> list) {');
    gen.writeln('for (vms.${name} elem in list) {');
    gen.writeln('assert${name}(elem);');
    gen.writeln('}');
    gen.writeln('return list;');
    gen.writeln('}');
    gen.writeln('');
  }

  void _parse(Token token) {
    new TypeParser(token).parseInto(this);
  }

  void removeDuplicateFieldDefs() {
    for (TypeField field in fields.toList()) {
      if (superName == null) continue;

      if (getSuper().hasField(field.name)) {
        print('Removing duplicate field def: ${name}.${field.name}.');
        fields.remove(field);
      }
    }
  }

  bool hasField(String name) {
    if (fields.any((field) => field.name == name)) return true;
    return getSuper()?.hasField(name) ?? false;
  }
}

class TypeField extends Member {
  static final Map<String, String> _nameRemap = {
    'const': 'isConst',
    'final': 'isFinal',
    'static': 'isStatic',
    'abstract': 'isAbstract',
    'super': 'superClass',
    'class': 'classRef',
    'new': 'new_',
  };

  final Type parent;
  final String _docs;
  MemberType type = new MemberType();
  String name;
  bool optional = false;
  String defaultValue;

  TypeField(this.parent, this._docs);

  String get docs {
    String str = _docs == null ? '' : _docs;
    if (type.isMultipleReturns) {
      str += '\n\n[${generatableName}] can be one of '
          '${joinLast(type.types.map((t) => '[${t}]'), ', ', ' or ')}.';
      str = str.trim();
    }
    return str;
  }

  String get generatableName {
    return _nameRemap[name] != null ? _nameRemap[name] : name;
  }

  void generate(DartGenerator gen) {
    if (docs.isNotEmpty) gen.writeDocs(docs);
    if (optional) gen.write('@optional ');
    String typeName =
        api.isEnumName(type.name) ? '/*${type.name}*/ String' : type.name;
    gen.writeStatement('${typeName} ${generatableName};');
    if (parent.fields.any((field) => field.hasDocs)) gen.writeln();
  }
}

class Enum extends Member {
  final String name;
  final String docs;

  List<EnumValue> enums = [];

  Enum(this.name, String definition, [this.docs]) {
    _parse(new Tokenizer(definition).tokenize());
  }

  Enum._(this.name, this.docs);

  factory Enum.merge(Enum e1, Enum e2) {
    final String name = e1.name;
    final String docs = [e1.docs, e2.docs].where((e) => e != null).join('\n');
    final Map<String, EnumValue> map = <String, EnumValue>{};
    for (EnumValue e in e2.enums.reversed) {
      map[e.name] = e;
    }
    // The official service.md is the default
    for (EnumValue e in e1.enums.reversed) {
      map[e.name] = e;
    }

    final enums = map.values.toList().reversed.toList();

    return new Enum._(name, docs)..enums = enums;
  }

  String get prefix =>
      name.endsWith('Kind') ? name.substring(0, name.length - 4) : name;

  void generate(DartGenerator gen) {
    gen.writeln();
    if (docs != null) gen.writeDocs(docs);
    gen.writeStatement('class ${name} {');
    gen.writeStatement('${name}._();');
    gen.writeln();
    enums.forEach((e) => e.generate(gen));
    gen.writeStatement('}');
  }

  void generateAssert(DartGenerator gen) {
    gen.writeln('String assert${name}(String obj) {');
    List<EnumValue> sorted = enums.toList()
      ..sort((EnumValue e1, EnumValue e2) => e1.name.compareTo(e2.name));
    for (EnumValue value in sorted) {
      gen.writeln('  if (obj == "${value.name}") return obj;');
    }
    gen.writeln('  throw "invalid ${name}: \$obj";');
    gen.writeln('}');
    gen.writeln('');
  }

  void _parse(Token token) {
    new EnumParser(token).parseInto(this);
  }
}

class EnumValue extends Member {
  final Enum parent;
  final String name;
  final String docs;

  EnumValue(this.parent, this.name, [this.docs]);

  bool get isLast => parent.enums.last == this;

  void generate(DartGenerator gen) {
    if (docs != null) gen.writeDocs(docs);
    gen.writeStatement("static const String k${name} = '${name}';");
  }
}

class TextOutputVisitor implements NodeVisitor {
  static String printText(Node node) {
    TextOutputVisitor visitor = new TextOutputVisitor();
    node.accept(visitor);
    return visitor.toString();
  }

  StringBuffer buf = new StringBuffer();
  bool _em = false;
  bool _href = false;
  bool _blockquote = false;

  TextOutputVisitor();

  bool visitElementBefore(Element element) {
    if (element.tag == 'em') {
      buf.write('`');
      _em = true;
    } else if (element.tag == 'p') {
      // Nothing to do.
    } else if (element.tag == 'blockquote') {
      buf.write('```\n');
      _blockquote = true;
    } else if (element.tag == 'a') {
      _href = true;
    } else {
      print('unknown tag: ${element.tag}');
      buf.write(renderToHtml([element]));
    }

    return true;
  }

  void visitText(Text text) {
    String t = text.text;
    if (_em) {
      t = _coerceRefType(t);
    } else if (_href) {
      t = '[${_coerceRefType(t)}]';
    }

    if (_blockquote) {
      buf.write('${t}\n```');
    } else {
      buf.write(t);
    }
  }

  void visitElementAfter(Element element) {
    if (element.tag == 'p') {
      buf.write('\n\n');
    } else if (element.tag == 'a') {
      _href = false;
    } else if (element.tag == 'blockquote') {
      //buf.write('```\n');
      _blockquote = false;
    } else if (element.tag == 'em') {
      buf.write('`');
      _em = false;
    }
  }

  String toString() => buf.toString().trim();
}

// @Instance|@Error|Sentinel evaluate(
//     string isolateId,
//     string targetId [optional],
//     string expression)
class MethodParser extends Parser {
  MethodParser(Token startToken) : super(startToken);

  void parseInto(Method method) {
    // method is return type, name, (, args )
    // args is type name, [optional], comma

    method.returnType.parse(this);

    Token t = expectName();
    validate(
        t.text == method.name, 'method name ${method.name} equals ${t.text}');

    expect('(');

    while (peek().text != ')') {
      Token type = expectName();
      TypeRef ref = new TypeRef(_coerceRefType(type.text));
      if (peek().text == '[') {
        while (consume('[')) {
          expect(']');
          ref.arrayDepth++;
        }
      } else if (peek().text == '<') {
        // handle generics
        expect('<');
        ref.genericTypes = [];
        while (peek().text != '>') {
          Token genericTypeName = expectName();
          ref.genericTypes
              .add(new TypeRef(_coerceRefType(genericTypeName.text)));
          consume(',');
        }
        expect('>');
      }

      Token name = expectName();
      MethodArg arg = new MethodArg(method, ref, name.text);
      if (consume('[')) {
        expect('optional');
        expect(']');
        arg.optional = true;
      }
      method.args.add(arg);
      consume(',');
    }

    expect(')');

    method.args.sort((MethodArg a, MethodArg b) {
      if (!a.optional && b.optional) return -1;
      if (a.optional && !b.optional) return 1;
      return 0;
    });
  }
}

class TypeParser extends Parser {
  TypeParser(Token startToken) : super(startToken);

  void parseInto(Type type) {
    // class ClassList extends Response {
    //   // Docs here.
    //   @Class[] classes [optional];
    // }
    expect('class');

    Token t = expectName();
    type.rawName = t.text;
    type.name = _coerceRefType(type.rawName);
    if (consume('extends')) {
      t = expectName();
      type.superName = _coerceRefType(t.text);
    }

    expect('{');

    while (peek().text != '}') {
      TypeField field = new TypeField(type, collectComments());
      field.type.parse(this);
      field.name = expectName().text;
      if (consume('[')) {
        expect('optional');
        expect(']');
        field.optional = true;
      }
      type.fields.add(field);
      expect(';');
    }

    expect('}');
  }
}

class EnumParser extends Parser {
  EnumParser(Token startToken) : super(startToken);

  void parseInto(Enum e) {
    // enum ErrorKind { UnhandledException, Foo, Bar }
    // enum name { (comment* name ,)+ }
    expect('enum');

    Token t = expectName();
    validate(t.text == e.name, 'enum name ${e.name} equals ${t.text}');
    expect('{');

    while (!t.eof) {
      if (consume('}')) break;
      String docs = collectComments();
      t = expectName();
      consume(',');

      e.enums.add(new EnumValue(e, t.text, docs));
    }
  }
}
