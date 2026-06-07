import 'supabase_service.dart';

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
  final SupabaseService _supabaseService;

  DatabaseService(this._supabaseService);

  Future<bool> addMove(
    String gameId,
    String fen,
    int moveNumber,
    int whiteTime,
    int blackTime,
  ) async {
    return await _supabaseService.addMove(
      gameId: gameId,
      fen: fen,
      moveNumber: moveNumber,
      whiteTime: whiteTime,
      blackTime: blackTime,
    );
  }

  Future<List<GameMove>> getMoves(String gameId, {int fromMoveNumber = 0}) async {
    final movesData = await _supabaseService.getMoves(gameId, fromMoveNumber: fromMoveNumber);
    
    return movesData.map((data) => GameMove(
      gameId: data['game_id'] as String,
      fen: data['fen'] as String,
      moveNumber: data['move_number'] as int,
      whiteTime: _parseDuration(data['white_time_remaining']),
      blackTime: _parseDuration(data['black_time_remaining']),
      createdAt: DateTime.parse(data['created_at'] as String),
    )).toList();
  }

  Future<GameMove?> getInitialPosition(String gameId) async {
    final moves = await getMoves(gameId, fromMoveNumber: 0);
    if (moves.isEmpty) return null;
    return moves.first;
  }

  Future<int> getLastMoveNumber(String gameId) async {
    final lastMoveNumber = await _supabaseService.getLastMoveNumber(gameId);
    return lastMoveNumber ?? 0;
  }

  Future<void> deleteGameMoves(String gameId) async {
    // Supabase doesn't have a direct method for this, can be added if needed
    // For now, this is a placeholder
  }

  void close() {
    // Supabase client doesn't need explicit closing
  }

  int _parseDuration(String durationStr) {
    // Parse PostgreSQL interval format to seconds
    // Example: "00:05:00" -> 300 seconds
    final parts = durationStr.split(':');
    if (parts.length == 3) {
      final hours = int.parse(parts[0]);
      final minutes = int.parse(parts[1]);
      final seconds = int.parse(parts[2]);
      return hours * 3600 + minutes * 60 + seconds;
    }
    return 0;
  }
}