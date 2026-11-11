/// A headless peer for the E2E suites: a second person in the room, driven from a
/// shell or a test, speaking the game socket through the production
/// [DirectCollector].
///
/// It is the other user in the simulator suite (the app watches while the bot
/// walks up, waves, invites) and the seed of the M6 load harness, so it is built
/// on exactly the client code a phone runs — not on a reimplementation of the
/// wire — and every command answers with one JSON line on stdout that a script
/// can wait on. Logs go to stderr.
///
/// ```sh
/// set -a; . <bether-backend>/e2e/.env.generated; set +a
/// dart run bin/e2e_bot.dart --as bob join "$BETHER_E2E_SPACE_ID"
/// dart run bin/e2e_bot.dart --as bob move 6 4
/// dart run bin/e2e_bot.dart --as bob serve      # then one command per stdin line
/// ```
///
/// Against a stack started by `scripts/e2e.sh` only: it reads OTP codes from the
/// unauthenticated `/__e2e/mailbox` hook.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gather_client/gather_client.dart';

import '../test/e2e/harness.dart';

const usage = '''
usage: e2e_bot [options] <command> [args]

options:
  --url <base>        backend root (default: \$BETHER_E2E_URL)
  --as <name>         a seeded account (alice, bob): email + password from
                      \$BETHER_E2E_<NAME>_EMAIL / _PASSWORD
  --email <address>   sign in as this address (OTP via /__e2e/mailbox unless
                      --password is given); default: a fresh account per run
  --password <pw>     sign in by password instead of OTP
  --register          create the password account first
  --space <id>        join this space before the command
                      (default for --as: \$BETHER_E2E_SPACE_ID)
  -h, --help          this text

commands:
  login                         sign in and print who we are
  join <spaceId>                join (membership + game socket) and print the roster
  move <x> <y>                  teleport to a tile and wait until the server has us there
  walk <Up|Down|Left|Right> [n] take n single steps (default 1), stopping at a wall
  wave <spaceUserId>            wave at someone in the room
  roster                        print who is in the room
  serve                         stay connected and read one command per stdin line
                                (join / move / walk / wave / roster / quit)
''';

/// A command line the bot could not make sense of.
class BotUsageException implements Exception {
  const BotUsageException(this.message);

  final String message;

  @override
  String toString() => 'BotUsageException($message)';
}

/// One thing the bot is asked to do. The same vocabulary on the command line and,
/// for `serve`, on each stdin line — so a sim test scripts exactly what a person
/// would type.
sealed class BotCommand {
  const BotCommand();

  String get name;
}

final class LoginCommand extends BotCommand {
  const LoginCommand();
  @override
  String get name => 'login';
}

final class JoinCommand extends BotCommand {
  const JoinCommand(this.spaceId);
  final String spaceId;
  @override
  String get name => 'join';
}

final class MoveCommand extends BotCommand {
  const MoveCommand(this.x, this.y);
  final int x;
  final int y;
  @override
  String get name => 'move';
}

final class WalkCommand extends BotCommand {
  const WalkCommand(this.direction, this.steps);
  final String direction;
  final int steps;
  @override
  String get name => 'walk';
}

final class WaveCommand extends BotCommand {
  const WaveCommand(this.target);
  final String target;
  @override
  String get name => 'wave';
}

final class RosterCommand extends BotCommand {
  const RosterCommand();
  @override
  String get name => 'roster';
}

final class ServeCommand extends BotCommand {
  const ServeCommand();
  @override
  String get name => 'serve';
}

final class QuitCommand extends BotCommand {
  const QuitCommand();
  @override
  String get name => 'quit';
}

/// Everything the command line said, resolved against the environment.
class BotOptions {
  const BotOptions({
    required this.url,
    required this.command,
    this.email,
    this.password,
    this.register = false,
    this.spaceId,
  });

  final Uri url;
  final BotCommand command;

  /// Null means "a fresh account": a unique address signed up over OTP.
  final String? email;

  /// Non-null means password sign-in rather than OTP.
  final String? password;
  final bool register;

  /// Joined before [command] runs.
  final String? spaceId;
}

/// Parses the process arguments. [environment] supplies the defaults the runner
/// wrote to `e2e/.env.generated`.
BotOptions parseBotArgs(List<String> args, Map<String, String> environment) {
  String? url = environment['BETHER_E2E_URL'];
  String? as, email, password, spaceId;
  var register = false;
  final rest = <String>[];

  String value(int i, String flag) {
    if (i >= args.length || args[i].startsWith('--')) {
      throw BotUsageException('$flag needs a value');
    }
    return args[i];
  }

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--url':
        url = value(++i, arg);
      case '--as':
        as = value(++i, arg).toLowerCase();
      case '--email':
        email = value(++i, arg);
      case '--password':
        password = value(++i, arg);
      case '--register':
        register = true;
      case '--space':
        spaceId = value(++i, arg);
      case '-h' || '--help':
        throw const BotUsageException('help');
      default:
        if (arg.startsWith('-') && rest.isEmpty)
          throw BotUsageException('unknown option $arg');
        rest.add(arg);
    }
  }

  if (url == null || url.isEmpty) {
    throw const BotUsageException(
      'no backend: pass --url or source e2e/.env.generated',
    );
  }
  final base = Uri.tryParse(url.replaceFirst(RegExp(r'/+$'), ''));
  if (base == null || !base.hasScheme || base.host.isEmpty) {
    throw BotUsageException('--url is not an http(s) URL: $url');
  }

  if (as != null) {
    if (email != null)
      throw const BotUsageException('--as and --email are exclusive');
    final p = 'BETHER_E2E_${as.toUpperCase()}';
    email = environment['${p}_EMAIL'];
    password ??= environment['${p}_PASSWORD'];
    if (email == null || password == null) {
      throw BotUsageException(
        'no seeded account "$as" in the environment (run scripts/e2e.sh seed)',
      );
    }
    spaceId ??= environment['BETHER_E2E_SPACE_ID'];
  }
  if (register && password == null)
    throw const BotUsageException('--register needs --password');
  if (register && email == null)
    throw const BotUsageException('--register needs --email');

  if (rest.isEmpty) throw const BotUsageException('no command');
  final command = parseBotCommand(rest, allowProcessCommands: true);
  return BotOptions(
    url: base,
    command: command,
    email: email,
    password: password,
    register: register,
    spaceId: spaceId,
  );
}

/// Parses one `serve` line. Blank lines and `#` comments are null.
BotCommand? parseBotLine(String line) {
  final words = line
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty || words.first.startsWith('#')) return null;
  return parseBotCommand(words, allowProcessCommands: false);
}

/// The shared grammar. `login` and `serve` only make sense as the process's own
/// command; `quit` only inside `serve`.
BotCommand parseBotCommand(
  List<String> words, {
  required bool allowProcessCommands,
}) {
  final verb = words.first;
  final args = words.sublist(1);

  void arity(int min, [int? max]) {
    if (args.length < min || args.length > (max ?? min)) {
      throw BotUsageException(
        '$verb takes ${max == null || max == min ? '$min' : '$min–$max'} '
        'argument${(max ?? min) == 1 ? '' : 's'}, got ${args.length}',
      );
    }
  }

  int integer(String text, String what) {
    final n = int.tryParse(text);
    if (n == null)
      throw BotUsageException('$what must be an integer, got "$text"');
    return n;
  }

  switch (verb) {
    case 'login' when allowProcessCommands:
      arity(0);
      return const LoginCommand();
    case 'serve' when allowProcessCommands:
      arity(0);
      return const ServeCommand();
    case 'quit' || 'exit' when !allowProcessCommands:
      arity(0);
      return const QuitCommand();
    case 'join':
      arity(1);
      return JoinCommand(args[0]);
    case 'move':
      arity(2);
      return MoveCommand(integer(args[0], 'x'), integer(args[1], 'y'));
    case 'walk':
      arity(1, 2);
      final direction = _directions[args[0].toLowerCase()];
      if (direction == null) {
        throw BotUsageException(
          'walk direction must be one of Up, Down, Left, Right, got "${args[0]}"',
        );
      }
      final steps = args.length > 1 ? integer(args[1], 'steps') : 1;
      if (steps < 1)
        throw BotUsageException('steps must be at least 1, got $steps');
      return WalkCommand(direction, steps);
    case 'wave':
      arity(1);
      return WaveCommand(args[0]);
    case 'roster':
      arity(0);
      return const RosterCommand();
    default:
      throw BotUsageException('unknown command "$verb"');
  }
}

/// Case-insensitive on the way in; the wire wants Gather's capitalised names.
final _directions = {for (final d in moveDirections) d.toLowerCase(): d};

const _stepDelta = {
  'Up': (dx: 0, dy: -1),
  'Down': (dx: 0, dy: 1),
  'Left': (dx: -1, dy: 0),
  'Right': (dx: 1, dy: 0),
};

/// How long one step gets to show up on our own roster before it counts as
/// blocked. The server applies a legal step within a frame; only a wall is slow.
const _stepPatience = Duration(seconds: 3);

/// The running peer: one signed-in person and, once joined, one socket.
class Bot {
  Bot._(this._env, this._user, this._log);

  static Future<Bot> signIn(
    BotOptions options, {
    void Function(String)? log,
  }) async {
    final logger = log ?? (_) {};
    final env = E2eEnv.load({
      ...Platform.environment,
      'BETHER_E2E_URL': options.url.toString(),
    })!;
    final config = await discover(env.base);
    final email = options.email ?? uniqueEmail('bot');
    final password = options.password;
    final credentials = password != null
        ? await passwordCredentials(
            config,
            email,
            password,
            register: options.register,
          )
        : await otpCredentials(env, config, email);
    logger('bot: signed in as $email (${credentials.uid})');
    return Bot._(
      env,
      E2eUser(
        email: email,
        credentials: credentials,
        config: config,
        log: logger,
      ),
      logger,
    );
  }

  final E2eEnv _env;
  final E2eUser _user;
  final void Function(String) _log;
  DirectCollector? _collector;
  String? _spaceId;

  E2eEnv get env => _env;

  Map<String, Object?> get identity => {
    'email': _user.email,
    'userId': _user.userId,
  };

  /// Runs one command and answers with what a script needs to know.
  Future<Map<String, Object?>> run(BotCommand command) async {
    switch (command) {
      case LoginCommand():
        return identity;
      case JoinCommand(:final spaceId):
        return _join(spaceId);
      case MoveCommand(:final x, :final y):
        final collector = _joined();
        final sent = collector.teleport(x: x, y: y);
        if (!sent.ok) throw StateError(sent.detail ?? 'teleport refused');
        await _selfAt(collector, x, y, const Duration(seconds: 10));
        return {'x': x, 'y': y};
      case WalkCommand(:final direction, :final steps):
        return _walk(direction, steps);
      case WaveCommand(:final target):
        final sent = _joined().wave(target);
        if (!sent.ok) throw StateError(sent.detail ?? 'wave refused');
        return {'target': target};
      case RosterCommand():
        return _rosterJson(_joined().reader.roster());
      case ServeCommand() || QuitCommand():
        throw StateError('${command.name} is not a step');
    }
  }

  Future<Map<String, Object?>> _join(String spaceId) async {
    final spaceUserId = await _user.rest.join(spaceId);
    await _collector?.dispose();
    final collector = _collector = _user.collector(spaceId: spaceId, log: _log)
      ..start();
    _spaceId = spaceId;
    final roster = await connected(
      collector,
      timeout: const Duration(seconds: 20),
    );
    if (roster.selfId != spaceUserId) {
      throw StateError(
        'socket says we are ${roster.selfId}, REST said $spaceUserId',
      );
    }
    return {
      'spaceId': spaceId,
      'spaceUserId': spaceUserId,
      ..._rosterJson(roster),
    };
  }

  Future<Map<String, Object?>> _walk(String direction, int steps) async {
    final collector = _joined();
    final delta = _stepDelta[direction]!;
    var taken = 0;
    var (x, y) = _position(collector);
    for (; taken < steps; taken++) {
      final sent = collector.move(direction: direction);
      if (!sent.ok) throw StateError(sent.detail ?? 'move refused');
      final next = (x + delta.dx, y + delta.dy);
      try {
        await _selfAt(collector, next.$1, next.$2, _stepPatience);
      } on TimeoutException {
        break; // a wall: the server turned us and did not move us
      }
      (x, y) = next;
    }
    return {
      'direction': direction,
      'steps': taken,
      'x': x,
      'y': y,
      'blocked': taken < steps,
    };
  }

  DirectCollector _joined() {
    final collector = _collector;
    if (collector == null)
      throw StateError('not in a space yet — join <spaceId> first');
    return collector;
  }

  (int, int) _position(DirectCollector collector) {
    final self = rowOf(collector.reader.roster(), collector.selfId);
    final x = self?.x, y = self?.y;
    if (x == null || y == null)
      throw StateError('our own position is not known yet');
    return (x.toInt(), y.toInt());
  }

  Future<void> _selfAt(
    DirectCollector collector,
    int x,
    int y,
    Duration timeout,
  ) => rosterWhere(
    collector,
    (r) {
      final self = rowOf(r, r.selfId);
      return self?.x == x && self?.y == y;
    },
    reason: 'ourselves at ($x, $y)',
    timeout: timeout,
  );

  Map<String, Object?> _rosterJson(Roster roster) => {
    'spaceId': _spaceId,
    'selfId': roster.selfId,
    'rows': [
      for (final row in roster.rows)
        {
          'id': row.id,
          'name': row.name,
          'x': row.x,
          'y': row.y,
          'connected': row.connected,
          'clusterId': row.clusterId,
        },
    ],
  };

  Future<void> close() async {
    await _collector?.dispose();
    _collector = null;
  }
}

void _reply(String command, Map<String, Object?> fields, {bool ok = true}) =>
    stdout.writeln(jsonEncode({'ok': ok, 'cmd': command, ...fields}));

Future<void> main(List<String> args) async {
  final BotOptions options;
  try {
    options = parseBotArgs(args, Platform.environment);
  } on BotUsageException catch (e) {
    if (e.message == 'help') {
      stdout.write(usage);
      return;
    }
    stderr
      ..writeln('e2e_bot: ${e.message}')
      ..write(usage);
    exitCode = 64; // EX_USAGE
    return;
  }

  final log = stderr.writeln;
  Bot? bot;
  try {
    bot = await Bot.signIn(options, log: log);
    if (options.spaceId != null && options.command is! JoinCommand) {
      await bot.run(JoinCommand(options.spaceId!));
    }
    if (options.command is ServeCommand) {
      await _serve(bot);
    } else {
      _reply(options.command.name, await bot.run(options.command));
    }
  } on Object catch (error) {
    _reply(options.command.name, {'error': '$error'}, ok: false);
    exitCode = 1;
  } finally {
    await bot?.close();
  }
}

/// One command per stdin line, one JSON reply per command, in order. A failed
/// command answers `ok: false` and the bot stays up — a sim test that asked for
/// something impossible should see why, not lose its peer. EOF is a quit.
Future<void> _serve(Bot bot) async {
  _reply('serve', {'event': 'ready', ...bot.identity});
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    final BotCommand? command;
    try {
      command = parseBotLine(line);
    } on BotUsageException catch (e) {
      _reply(line.trim().split(' ').first, {'error': e.message}, ok: false);
      continue;
    }
    if (command == null) continue;
    if (command is QuitCommand) break;
    try {
      _reply(command.name, await bot.run(command));
    } on Object catch (error) {
      _reply(command.name, {'error': '$error'}, ok: false);
    }
  }
  _reply('quit', const {});
}
