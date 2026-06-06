import 'dart:math';
import 'package:bishop/bishop.dart';

class ChessValidator {
  final Map<String, Variant> _variants = {};
  final Random _random = Random();

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

  bool validateMove(String fen, String variant) {
    if (!isVariantSupported(variant)) {
      return false;
    }

    try {
      final v = _variants[variant]!;
      // Проверяем валидность FEN через bishop
      final game = Game(variant: v);
      game.loadFen(fen);
      return true;
    } catch (e) {
      return false;
    }
  }

  String getInitialFen(String variant) {
    if (!isVariantSupported(variant)) {
      // Возвращаем стандартную позицию если вариант не поддерживается
      final game = Game(variant: Variant.standard());
      return game.fen;
    }

    final v = _variants[variant]!;

    if (variant == 'chess960') {
      // Генерируем случайную начальную позицию для chess960
      return _generateRandomChess960Position();
    }

    final game = Game(variant: v);
    return game.fen;
  }

  String _generateRandomChess960Position() {
    // Генерация случайной позиции chess960 по алгоритму
    final n = _random.nextInt(960);
    
    // Массив из 8 позиций (0-7) для фигур
    final board = List<String>.filled(8, '');
    
    // 1. Расстановка слонов
    // Белопольный слон: поля [1, 3, 5, 7]
    final whiteBishopIndex = n % 4;
    final whiteBishopPos = [1, 3, 5, 7][whiteBishopIndex];
    board[whiteBishopPos] = 'B';
    
    var currentN = n ~/ 4;
    
    // Чернопольный слон: поля [0, 2, 4, 6]
    final blackBishopIndex = currentN % 4;
    final blackBishopPos = [0, 2, 4, 6][blackBishopIndex];
    board[blackBishopPos] = 'B';
    
    currentN = currentN ~/ 4;
    
    // 2. Расстановка ферзя
    // Получаем список свободных полей
    final freeFields = <int>[];
    for (int i = 0; i < 8; i++) {
      if (board[i].isEmpty) {
        freeFields.add(i);
      }
    }
    
    final queenIndex = currentN % 6;
    final queenPos = freeFields[queenIndex];
    board[queenPos] = 'Q';
    
    currentN = currentN ~/ 6;
    
    // 3. Расстановка коней
    // Получаем обновленный список свободных полей
    final freeFieldsAfterQueen = <int>[];
    for (int i = 0; i < 8; i++) {
      if (board[i].isEmpty) {
        freeFieldsAfterQueen.add(i);
      }
    }
    
    // Комбинации для двух коней на 5 местах
    final knightCombinations = [
      [0, 1], [0, 2], [0, 3], [0, 4],
      [1, 2], [1, 3], [1, 4],
      [2, 3], [2, 4],
      [3, 4]
    ];
    
    final knightComboIndex = currentN % 10;
    final knightIndices = knightCombinations[knightComboIndex];
    
    final knight1Pos = freeFieldsAfterQueen[knightIndices[0]];
    final knight2Pos = freeFieldsAfterQueen[knightIndices[1]];
    board[knight1Pos] = 'N';
    board[knight2Pos] = 'N';
    
    // 4. Расстановка короля и ладей
    // Получаем последние 3 свободных поля
    final freeFieldsAfterKnights = <int>[];
    for (int i = 0; i < 8; i++) {
      if (board[i].isEmpty) {
        freeFieldsAfterKnights.add(i);
      }
    }
    
    // Сортируем свободные поля
    freeFieldsAfterKnights.sort();
    
    // Ладья - король - ладья
    board[freeFieldsAfterKnights[0]] = 'R';
    board[freeFieldsAfterKnights[1]] = 'K';
    board[freeFieldsAfterKnights[2]] = 'R';
    
    // Генерируем FEN строку
    final pieces = board.join();
    
    // Полная FEN для chess960: [позиция белых] / [позиция черных] w KQkq - 0 1
    // Черные фигуры - зеркальное отражение белых (меняем регистр)
    final blackPieces = pieces.split('').map((c) => c.toLowerCase()).join();
    
    final fen = '$blackPieces/pppppppp/8/8/8/8/PPPPPPPP/$pieces w KQkq - 0 1';
  
    
    return fen;
  }

  Variant? getVariant(String variant) {
    return _variants[variant];
  }
}
