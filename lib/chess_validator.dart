import 'package:bishop/bishop.dart';

class MoveResult {
  final bool success;
  final String? newFen;
  final String? error;

  MoveResult({required this.success, this.newFen, this.error});
}

class GameEndResult {
  final bool isGameOver;
  final String? result; // '1-0', '0-1', '1/2-1/2', '*'
  final String? reason; // 'checkmate', 'stalemate', 'draw'

  GameEndResult({
    required this.isGameOver,
    this.result,
    this.reason,
  });
}

class ChessValidator {
  final Map<String, Variant> _variants = {};

  ChessValidator() {
    _initializeVariants();
  }

  void _initializeVariants() {
    _variants['standard'] = Variant.standard();
    _variants['chess960'] = Variant.chess960();
    _variants['mini'] = Variant.mini();
    _variants['micro'] = Variant.micro();
    _variants['nano'] = Variant.nano();
    _variants['grand'] = Variant.grand();
    _variants['capablanca'] = Variant.capablanca();
    _variants['crazyhouse'] = Variant.crazyhouse();
    _variants['seirawan'] = Variant.seirawan();
    _variants['atomic'] = Variant.atomic();
    _variants['kingOfTheHill'] = Variant.kingOfTheHill();
    _variants['horde'] = Variant.horde();
  }

  bool isVariantSupported(String variant) {
    return _variants.containsKey(variant);
  }

  // Применяет UCI-ход (например "e2e4") к текущей позиции
  MoveResult applyMove(String currentFen, String move, String variant) {
    if (!isVariantSupported(variant)) {
      return MoveResult(success: false, error: 'Unsupported variant');
    }

    try {
      final v = _variants[variant]!;
      final game = Game(variant: v);
      game.loadFen(currentFen);

      // bishop использует makeMoveString для применения UCI хода
      final success = game.makeMoveString(move);

      if (!success) {
        return MoveResult(success: false, error: 'Illegal move');
      }

      return MoveResult(success: true, newFen: game.fen);
    } on FormatException catch (_) {
      return MoveResult(success: false, error: 'Invalid move format');
    } catch (e) {
      return MoveResult(success: false, error: 'Move error: $e');
    }
  }

  // Определяет чей ход ('w' или 'b')
  String? getCurrentTurn(String fen) {
    try {
      final parts = fen.split(' ');
      if (parts.length < 2) return null;
      return parts[1];
    } catch (e) {
      return null;
    }
  }

  // Проверяет окончание игры (мат, пат, ничья)
  GameEndResult checkGameEnd(String fen, String variant) {
    try {
      final v = _variants[variant]!;
      final game = Game(variant: v);
      game.loadFen(fen);

      if (game.gameOver) {
        return GameEndResult(
          isGameOver: true,
          result: game.result?.toString(),
          reason: 'game_over',
        );
      }

      return GameEndResult(isGameOver: false);
    } catch (e) {
      return GameEndResult(isGameOver: false);
    }
  }

  @Deprecated('Use applyMove instead')
  bool validateMove(String fen, String variant) {
    if (!isVariantSupported(variant)) {
      return false;
    }

    try {
      final v = _variants[variant]!;
      final game = Game(variant: v);
      game.loadFen(fen);
      return true;
    } catch (e) {
      return false;
    }
  }

  String getInitialFen(String variant) {
    if (!isVariantSupported(variant)) {
      final game = Game(variant: Variant.standard());
      return game.fen;
    }

    final v = _variants[variant]!;
    // Bishop сам генерирует корректную позицию с правильными castling rights
    final game = Game(variant: v);
    return game.fen;
  }

  Variant? getVariant(String variant) {
    return _variants[variant];
  }
}