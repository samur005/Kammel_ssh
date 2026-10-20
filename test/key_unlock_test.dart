import 'package:flutter_test/flutter_test.dart';
import 'dart:math';
import 'package:terminal_agent/services/key_unlock.dart';
import 'package:terminal_agent/services/reconnect_policy.dart';

// Throwaway keys generated with `ssh-keygen -N 'open sesame'` for this test.
const _ed = r'''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCJvlg7A2
46pQG9FE7iuLX1AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIKuSus2lsLprj9p+
j2kal9ss2gsaAi5sV/FJwkeN8KRtAAAAkPoCFRX77rtIklZw6ORkOnPsOkfGyUCFEY8FG1
pWevxGgbCzReh6JG1csyEgXq7MbnW5+iAzskAJtsEthjBCFE76CoPbgGhTHlstZ4vgACwc
4XWkv8UNwkhP2GATMFPi1gmbyjbQZC3iy5vQbeXmXxjlvQQoSK3HAu1Enn+pryrff6Fz8p
Ucnv5ODnFGZiNkZQ==
-----END OPENSSH PRIVATE KEY-----
''';
const _rsa = r'''-----BEGIN RSA PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-128-CBC,A56A2ADDA0DF28E361695583B87EA809

jnteT/+aO7YrTfPKuqXFXstgS4eU2TmBo56xk117Y4T6TzjmKE/deWuHx8NbgmFW
ZwbXq4kwEw9Cvo5YDo3QMe9MPHz9DxWo0n1JQCVninbCw0RZDet//B9sQn+QBmWL
q6TLUsDWaeTTOKK0DfTmKmKZ771HPR18TERqjSGonPvubUpCajO5UKbWCQMlrpTw
Oms/YenW4q1MYsDX+RXXcva5TfN5EJgn8LwYJXbd9jne6iZNg/diDTjktjdy7Bl4
Z5u/MjvYYBa47lfX0FTyQXq+quiyRwU+SeLbi4QLbGSHKe5a20NlU3xhCDDJx5ZQ
mqkpc4LAPRrpCvzj2sEpLQZDqXbtYV4Z7qD7TrXml+qC/8WOncTXWBGsSF+VRkdQ
x/LVD0IHQdKJykUrSs7vAVHwHeJU6Qqq/G/NkJEdtdRdFr/P2iV3USh/tYssEMSU
m3H5prTtaM8IYUHAF3NUh1SpFVBG9EWsPG2+YYsOO9g8IM/88mySJl8tcwuNBffo
Kni7zX0ixMBTWkk+Ryoc4BSNu/THBsf3nfK2M1b/2xQBsVsuqXnmmIy+R7LmcAnP
+EjZb9KkJWBbPnfwZ+XUqp+IARJWZRyey8SWRXhwctJy4aIIofN33GbLuGa+ht7B
WLaap/RJy3GDCy8OiYBuTT1lkPKpl7jM+JfH4vPjw7mDR4/BUzTh5vJvJnFFpuLM
WSRmv4Ft6ZMbUOjUUUiHhFFhebp8FHSMWh+8Tcdx4XQ6P/wXtEdvjZ0B+sPWbSXj
GnB9QP134flkgzn0kp8wlhjsCWJmDxqzrkB4BP0X+k201qazoEnuKKgBUSMdCS8s
-----END RSA PRIVATE KEY-----
''';

void main() {
  group('unlockPrivateKey', () {
    test('a remembered passphrase unlocks without asking', () async {
      var asked = 0;
      final keys = await unlockPrivateKey(_ed,
          candidates: ['open sesame'],
          ask: ({required retry}) async {
            asked++;
            return null;
          });
      expect(keys, isNotEmpty);
      expect(asked, 0);
    });

    test('asks, retries after a wrong one and remembers on request',
        () async {
      final answers = ['wrong', 'open sesame'];
      final retries = <bool>[];
      String? stored;
      final keys = await unlockPrivateKey(_ed,
          candidates: ['also wrong'],
          ask: ({required retry}) async {
            retries.add(retry);
            return (value: answers.removeAt(0), remember: true);
          },
          remember: (p) async => stored = p);
      expect(keys, isNotEmpty);
      expect(retries, [false, true]);
      expect(stored, 'open sesame');
    });

    test('legacy PEM (RSA, DEK-Info) works too', () async {
      final keys = await unlockPrivateKey(_rsa, ask: ({required retry}) async =>
          (value: 'open sesame', remember: false));
      expect(keys, isNotEmpty);
    });

    test('cancel and too many wrong attempts are distinct errors', () async {
      expect(
          unlockPrivateKey(_ed, ask: ({required retry}) async => null),
          throwsA(isA<KeyLockedError>()
              .having((e) => e.cancelled, 'cancelled', true)));
      expect(
          unlockPrivateKey(_ed,
              ask: ({required retry}) async => (value: 'x', remember: false)),
          throwsA(isA<KeyLockedError>()
              .having((e) => e.cancelled, 'cancelled', false)));
    });
  });

  group('reconnectDelay', () {
    test('doubles and caps', () {
      Duration d(int a) => reconnectDelay(a, jitter: 0);
      expect(d(0), const Duration(seconds: 1));
      expect(d(1), const Duration(seconds: 2));
      expect(d(3), const Duration(seconds: 8));
      expect(d(10), const Duration(seconds: 60));
    });

    test('jitter stays within bounds', () {
      final rnd = Random(1);
      for (var i = 0; i < 100; i++) {
        final ms = reconnectDelay(2, random: rnd).inMilliseconds;
        expect(ms, inInclusiveRange(3200, 4800));
      }
    });

    test('keepalive 0 disables it', () {
      expect(const ConnectionTuning(keepAliveSeconds: 0).keepAlive, isNull);
      expect(const ConnectionTuning().keepAlive, const Duration(seconds: 15));
    });
  });
}
