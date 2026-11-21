import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/features/media/presentation/save_attachment_native.dart';

void main() {
  test('publishes a staged attachment only after the whole download', () async {
    final directory = await Directory.systemTemp.createTemp('neko-attachment-');
    final destination = File.fromUri(directory.uri.resolve('attachment.bin'));
    addTearDown(() async {
      if (await destination.exists()) await destination.delete();
      await directory.delete();
    });
    await destination.writeAsBytes([9]);

    Stream<Uint8List> interrupted() async* {
      yield Uint8List.fromList([1, 2]);
      throw const FormatException('broken download');
    }

    await expectLater(
      saveAttachmentParts(destination, interrupted(), isCurrent: () => true),
      throwsFormatException,
    );
    expect(await destination.readAsBytes(), [9]);
    expect(await directory.list().length, 1);

    var current = true;
    Stream<Uint8List> expired() async* {
      yield Uint8List.fromList([1, 2]);
      current = false;
      yield Uint8List.fromList([3]);
    }

    await saveAttachmentParts(destination, expired(), isCurrent: () => current);
    expect(await destination.readAsBytes(), [9]);
    expect(await directory.list().length, 1);

    await saveAttachmentParts(
      destination,
      Stream.fromIterable([
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3]),
      ]),
      isCurrent: () => true,
    );
    expect(await destination.readAsBytes(), [1, 2, 3]);
    expect(await directory.list().length, 1);
  });
}
