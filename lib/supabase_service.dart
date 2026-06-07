import 'package:supabase/supabase.dart';

class SupabaseService {
  late final SupabaseClient _client;

  SupabaseService({
    required String supabaseUrl,
    required String supabaseAnonKey,
  }) {
    _client = SupabaseClient(
      supabaseUrl,
      supabaseAnonKey,
    );
  }

  SupabaseClient get client => _client;

  // Games table methods
  Future<Map<String, dynamic>?> getGame(String gameId) async {
    final response = await _client
        .from('games')
        .select()
        .eq('game_id', gameId)
        .single();
    
    return response;
  }

  Future<String> createGame({
    required String gameId,
    required String whiteId,
    required String blackId,
    required String variant,
    required String timeControlType,
    required String timeControl,
    required String initialFen,
    required String fen,
    required String status,
  }) async {
    await _client.from('games').insert({
      'game_id': gameId,
      'white_id': whiteId,
      'black_id': blackId,
      'variant': variant,
      'time_control_type': timeControlType,
      'time_control': timeControl,
      'initial_fen': initialFen,
      'fen': fen,
      'status': status,
      'created_at': DateTime.now().toIso8601String(),
      'last_move_at': DateTime.now().toIso8601String(),
    });
    return gameId;
  }

  Future<void> updateGame(String gameId, Map<String, dynamic> updates) async {
    await _client.from('games').update(updates).eq('game_id', gameId);
  }

  Future<void> updateGameFen(String gameId, String fen, int whiteTime, int blackTime) async {
    await _client.from('games').update({
      'fen': fen,
      'last_move_at': DateTime.now().toIso8601String(),
    }).eq('game_id', gameId);
  }

  Future<void> endGame(String gameId, String result, String termination) async {
    await _client.from('games').update({
      'status': 'ended',
      'result': result,
      'termination': termination,
      'last_move_at': DateTime.now().toIso8601String(),
    }).eq('game_id', gameId);
  }

  // Moves table methods
  Future<bool> addMove({
    required String gameId,
    required String fen,
    required int moveNumber,
    required int whiteTime,
    required int blackTime,
    String? san,
    String? uci,
  }) async {
    try {
      await _client.from('moves').insert({
        'game_id': gameId,
        'fen': fen,
        'move_number': moveNumber,
        'white_time_remaining': Duration(seconds: whiteTime).toString(),
        'black_time_remaining': Duration(seconds: blackTime).toString(),
        'san': san ?? '',
        'uci': uci ?? '',
        'fen_after': fen,
        'created_at': DateTime.now().toIso8601String(),
      });
      return true;
    } catch (e) {
      print('Error adding move: $e');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getMoves(String gameId, {int fromMoveNumber = 0}) async {
    final response = await _client
        .from('moves')
        .select()
        .eq('game_id', gameId)
        .gte('move_number', fromMoveNumber)
        .order('move_number', ascending: true);
    
    return List<Map<String, dynamic>>.from(response);
  }

  Future<int?> getLastMoveNumber(String gameId) async {
    final response = await _client
        .from('moves')
        .select('move_number')
        .eq('game_id', gameId)
        .order('move_number', ascending: false)
        .limit(1);
    
    if (response.isEmpty) return null;
    return response[0]['move_number'] as int;
  }

  // Ratings table methods
  Future<Map<String, dynamic>?> getRating(String userId, String variantKey, String timeControlType) async {
    final response = await _client
        .from('ratings')
        .select()
        .eq('user_id', userId)
        .eq('variant_key', variantKey)
        .eq('time_control_type', timeControlType)
        .maybeSingle();
    
    return response;
  }

  Future<void> updateRating({
    required String userId,
    required String variantKey,
    required String timeControlType,
    required int rating,
    required double rd,
    required double volatility,
  }) async {
    await _client.from('ratings').upsert({
      'user_id': userId,
      'variant_key': variantKey,
      'time_control_type': timeControlType,
      'rating': rating,
      'rd': rd,
      'volatility': volatility,
      'last_updated_at': DateTime.now().toIso8601String(),
    });
  }

  // Rating history table methods
  Future<void> addRatingHistory({
    required String userId,
    required String gameId,
    required int oldRating,
    required int newRating,
    required String variantKey,
    required String timeControlType,
  }) async {
    await _client.from('rating_history').insert({
      'user_id': userId,
      'game_id': gameId,
      'old_rating': oldRating,
      'new_rating': newRating,
      'variant_key': variantKey,
      'time_control_type': timeControlType,
      'created_at': DateTime.now().toIso8601String(),
    });
  }
}
