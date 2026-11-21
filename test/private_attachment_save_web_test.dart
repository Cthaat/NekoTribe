@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/features/media/presentation/save_attachment_web.dart';
import 'package:web/web.dart' as web;

void main() {
  for (final cancel in [false, true]) {
    test('browser attachment commits only while current ($cancel)', () async {
      final events = <Object>[];
      final writer = JSObject()
        ..setProperty(
          'write'.toJS,
          ((JSUint8Array chunk) {
            events.add([...chunk.toDart]);
            return Future<JSAny?>.value(null).toJS;
          }).toJS,
        )
        ..setProperty(
          'close'.toJS,
          (() {
            events.add('commit');
            return Future<JSAny?>.value(null).toJS;
          }).toJS,
        )
        ..setProperty(
          'abort'.toJS,
          (() {
            events.add('abort');
            return Future<JSAny?>.value(null).toJS;
          }).toJS,
        );
      final file = JSObject()
        ..setProperty(
          'createWritable'.toJS,
          (() => Future<JSObject>.value(writer).toJS).toJS,
        );
      final picker = 'showSaveFilePicker'.toJS;
      final original = web.window.getProperty<JSAny?>(picker);
      web.window.setProperty(
        picker,
        ((JSObject options) {
          events.add(
            options.getProperty<JSString>('suggestedName'.toJS).toDart,
          );
          return Future<JSObject>.value(file).toJS;
        }).toJS,
      );
      addTearDown(() => web.window.setProperty(picker, original));

      var current = true;
      Stream<Uint8List> parts() async* {
        yield Uint8List.fromList([1, 2]);
        if (cancel) current = false;
        yield Uint8List.fromList([3]);
      }

      await saveAttachment(
        'attachment.bin',
        readBytes: () async => throw StateError('unexpected buffered fallback'),
        readParts: parts,
        isCurrent: () => current,
      );
      expect(
        events,
        cancel
            ? [
                'attachment.bin',
                [1, 2],
                'abort',
              ]
            : [
                'attachment.bin',
                [1, 2],
                [3],
                'commit',
              ],
      );
    });
  }
}
