import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'chess_validator.dart';

class MatchmakingQueueEntry {
  final String userId;
  final String variantKey;
  final String timeControlType;
  final int rating;
  final int ratingRange;
  final DateTime enteredAt;
  WebSocketChannel? channel;

  MatchmakingQueueEntry({
    required this.userId,
    required this.variantKey,
    required this.timeControlType,
    required this.rating,
    required this.ratingRange,
    required this.enteredAt,
    this.channel,
  });
}

class GameSession {
  final String gameId;
  final String whiteId;
  final String blackId;
  final String variant;
  final String timeControl;
  final String status;
  final DateTime createdAt;
  final String? initialFen;

  GameSession({
    required this.gameId,
    required this.whiteId,
    required this.blackId,
    required this.variant,
    required this.timeControl,
    required this.status,
    required this.createdAt,
    this.initialFen,
  });

  Map<String, dynamic> toJson() {
    return {
      'game_id': gameId,
      'white_id': whiteId,
      'black_id': blackId,
      'variant': variant,
      'time_control': timeControl,
      'status': status,
      'created_at': createdAt.toIso8601String(),
      if (initialFen != null) 'initial_fen': initialFen,
    };
  }
}

class MatchmakingService {
  final List<MatchmakingQueueEntry> _queue = [];
  final Map<String, GameSession> _games = {};
  final Random _random = Random();
  final ChessValidator _chessValidator;

  MatchmakingService({ChessValidator? chessValidator})
      : _chessValidator = chessValidator ?? ChessValidator();

  MatchmakingResult findMatch(
    String userId,
    String variantKey,
    String timeControlType,
    int rating,
    int ratingRange,
    WebSocketChannel? channel,
  ) {
    // Проверяем, есть ли пользователь уже в очереди
    final existingIndex = _queue.indexWhere((e) => e.userId == userId);
    if (existingIndex != -1) {
      _queue.removeAt(existingIndex);
    }

    // Ищем оппонента с взаимным пересечением диапазонов рейтингов
    MatchmakingQueueEntry? opponent;
    int opponentIndex = -1;

    for (int i = 0; i < _queue.length; i++) {
      final entry = _queue[i];
      if (entry.variantKey == variantKey &&
          entry.timeControlType == timeControlType &&
          entry.userId != userId) {
        // Проверяем взаимное пересечение диапазонов
        final ratingDiff = (entry.rating - rating).abs();
        final minRange = min(ratingRange, entry.ratingRange);
        
        if (ratingDiff <= minRange) {
          opponent = entry;
          opponentIndex = i;
          break;
        }
      }
    }

    if (opponent != null) {
      // Удаляем оппонента из очереди
      _queue.removeAt(opponentIndex);

      // Получаем начальную FEN для варианта
      final initialFen = _chessValidator.getInitialFen(variantKey);

      // Создаем игру
      final game = createGame(userId, opponent.userId, variantKey, timeControlType, initialFen);

      // Отправляем уведомление оппоненту
      if (opponent.channel != null) {
        _sendMatchFoundNotification(opponent.channel!, game, opponent.userId == game.whiteId);
      }

      return MatchmakingResult(
        matchFound: true,
        gameId: game.gameId,
        whiteId: game.whiteId,
        blackId: game.blackId,
      );
    } else {
      // Добавляем пользователя в очередь
      final entry = MatchmakingQueueEntry(
        userId: userId,
        variantKey: variantKey,
        timeControlType: timeControlType,
        rating: rating,
        ratingRange: ratingRange,
        enteredAt: DateTime.now(),
        channel: channel,
      );
      _queue.add(entry);

      return MatchmakingResult(matchFound: false);
    }
  }

  GameSession createGame(
    String player1Id,
    String player2Id,
    String variant,
    String timeControl,
    String initialFen,
  ) {
    // Случайно назначаем цвета
    final isPlayer1White = _random.nextBool();
    
    final gameId = _generateGameId();
    
    final game = GameSession(
      gameId: gameId,
      whiteId: isPlayer1White ? player1Id : player2Id,
      blackId: isPlayer1White ? player2Id : player1Id,
      variant: variant,
      timeControl: timeControl,
      status: 'in_progress',
      createdAt: DateTime.now(),
      initialFen: initialFen,
    );

    _games[gameId] = game;
    return game;
  }

  void removeFromQueue(String userId) {
    _queue.removeWhere((e) => e.userId == userId);
  }

  GameSession? getGame(String gameId) {
    return _games[gameId];
  }

  List<MatchmakingQueueEntry> getQueue() {
    return List.from(_queue);
  }

  List<GameSession> getGames() {
    return _games.values.toList();
  }

  String _generateGameId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = _random.nextInt(10000);
    return '$timestamp-$random';
  }

  void _sendMatchFoundNotification(
    WebSocketChannel channel,
    GameSession game,
    bool isWhite,
  ) {
    final response = {
      'match_found': true,
      'game_id': game.gameId,
      'white_id': game.whiteId,
      'black_id': game.blackId,
      'your_color': isWhite ? 'white' : 'black',
    };
    channel.sink.add(response.toString());
  }
}

class MatchmakingResult {
  final bool matchFound;
  final String? gameId;
  final String? whiteId;
  final String? blackId;

  MatchmakingResult({
    required this.matchFound,
    this.gameId,
    this.whiteId,
    this.blackId,
  });

  Map<String, dynamic> toJson() {
    if (matchFound) {
      return {
        'match_found': true,
        'game_id': gameId,
        'white_id': whiteId,
        'black_id': blackId,
      };
    } else {
      return {'match_found': false};
    }
  }
}
