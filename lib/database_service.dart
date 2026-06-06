import 'package:sqlite3/sqlite3.dart';

class GameMove {
  final String gameId;
  final String fen;
  final int moveNumber;
  final int whiteTime;
  final int blackTime;
  final DateTime createdAt;

  GameMove({
    required this.gameId,
    required this.fen,
    required this.moveNumber,
    required this.whiteTime,
    required this.blackTime,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'game_id': gameId,
      'fen': fen,
      'move_number': moveNumber,
      'white_time': whiteTime,
      'black_time': blackTime,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory GameMove.fromMap(Map<String, dynamic> map) {
    return GameMove(
      gameId: map['game_id'] as String,
      fen: map['fen'] as String,
      moveNumber: map['move_number'] as int,
      whiteTime: map['white_time'] as int,
      blackTime: map['black_time'] as int,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

class DatabaseService {
  late Database _db;

  DatabaseService() {
    _initDatabase();
  }

  void _initDatabase() {
    final dbPath = 'chess_game.db';
    _db = sqlite3.open(dbPath);
    _createTables();
  }

  void _createTables() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS game_moves (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        game_id TEXT NOT NULL,
        fen TEXT NOT NULL,
        move_number INTEGER NOT NULL,
        white_time INTEGER NOT NULL,
        black_time INTEGER NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_game_moves_game_id 
      ON game_moves(game_id)
    ''');

    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_game_moves_move_number 
      ON game_moves(game_id, move_number)
    ''');
  }

  Future<void> addMove(
    String gameId,
    String fen,
    int moveNumber,
    int whiteTime,
    int blackTime,
  ) async {
    final stmt = _db.prepare('''
      INSERT INTO game_moves (game_id, fen, move_number, white_time, black_time, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    ''');

    stmt.execute([
      gameId,
      fen,
      moveNumber,
      whiteTime,
      blackTime,
      DateTime.now().toIso8601String(),
    ]);

    stmt.dispose();
  }

  Future<List<GameMove>> getMoves(String gameId, {int fromMoveNumber = 0}) async {
    final stmt = _db.prepare('''
      SELECT game_id, fen, move_number, white_time, black_time, created_at
      FROM game_moves
      WHERE game_id = ? AND move_number >= ?
      ORDER BY move_number ASC
    ''');

    final moves = <GameMove>[];
    final resultSet = stmt.select([gameId, fromMoveNumber]);
    
    for (final row in resultSet) {
      moves.add(GameMove(
        gameId: row['game_id'] as String,
        fen: row['fen'] as String,
        moveNumber: row['move_number'] as int,
        whiteTime: row['white_time'] as int,
        blackTime: row['black_time'] as int,
        createdAt: DateTime.parse(row['created_at'] as String),
      ));
    }

    stmt.dispose();
    return moves;
  }

  Future<GameMove?> getInitialPosition(String gameId) async {
    final moves = await getMoves(gameId, fromMoveNumber: 0);
    if (moves.isEmpty) return null;
    return moves.first;
  }

  Future<int> getLastMoveNumber(String gameId) async {
    final stmt = _db.prepare('''
      SELECT MAX(move_number) as max_move
      FROM game_moves
      WHERE game_id = ?
    ''');

    final resultSet = stmt.select([gameId]);
    
    if (resultSet.isNotEmpty) {
      final result = resultSet.first['max_move'];
      stmt.dispose();
      return result as int? ?? 0;
    }
    
    stmt.dispose();
    return 0;
  }

  Future<void> deleteGameMoves(String gameId) async {
    final stmt = _db.prepare('DELETE FROM game_moves WHERE game_id = ?');
    stmt.execute([gameId]);
    stmt.dispose();
  }

  void close() {
    _db.dispose();
  }
}
