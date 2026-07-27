class StockSourceDetails {
  final double price;
  final DateTime timestamp;
  final double? previousPrice;
  final DateTime? lastFlashTime;

  StockSourceDetails({
    required this.price,
    required this.timestamp,
    this.previousPrice,
    this.lastFlashTime,
  });

  StockSourceDetails copyWith({
    double? price,
    DateTime? timestamp,
    double? previousPrice,
    DateTime? lastFlashTime,
  }) {
    return StockSourceDetails(
      price: price ?? this.price,
      timestamp: timestamp ?? this.timestamp,
      previousPrice: previousPrice ?? this.previousPrice,
      lastFlashTime: lastFlashTime ?? this.lastFlashTime,
    );
  }
}

class StockRow {
  final String ticker;
  final StockSourceDetails nse;
  final StockSourceDetails bse;
  final StockSourceDetails yahoo;
  final StockSourceDetails broker;

  StockRow({
    required this.ticker,
    required this.nse,
    required this.bse,
    required this.yahoo,
    required this.broker,
  });

  factory StockRow.fromJson(Map<String, dynamic> json) {
    final ticker = json['ticker'] ?? '';

    StockSourceDetails parseSource(Map<String, dynamic>? data) {
      if (data == null) {
        return StockSourceDetails(price: 0.0, timestamp: DateTime.now());
      }
      return StockSourceDetails(
        price: data['price'] is num 
            ? (data['price'] as num).toDouble() 
            : double.parse(data['price'].toString()),
        timestamp: data['timestamp'] != null 
            ? DateTime.parse(data['timestamp']).toLocal() 
            : DateTime.now(),
      );
    }

    return StockRow(
      ticker: ticker,
      nse: parseSource(json['nse']),
      bse: parseSource(json['bse']),
      yahoo: parseSource(json['yahoo']),
      broker: parseSource(json['broker']),
    );
  }

  StockRow copyWithSource(String source, double newPrice, DateTime newTime) {
    final now = DateTime.now();
    switch (source.toLowerCase()) {
      case 'nse':
        return StockRow(
          ticker: ticker,
          nse: StockSourceDetails(
            price: newPrice,
            timestamp: newTime,
            previousPrice: nse.price,
            lastFlashTime: now,
          ),
          bse: bse,
          yahoo: yahoo,
          broker: broker,
        );
      case 'bse':
        return StockRow(
          ticker: ticker,
          nse: nse,
          bse: StockSourceDetails(
            price: newPrice,
            timestamp: newTime,
            previousPrice: bse.price,
            lastFlashTime: now,
          ),
          yahoo: yahoo,
          broker: broker,
        );
      case 'yahoo':
        return StockRow(
          ticker: ticker,
          nse: nse,
          bse: bse,
          yahoo: StockSourceDetails(
            price: newPrice,
            timestamp: newTime,
            previousPrice: yahoo.price,
            lastFlashTime: now,
          ),
          broker: broker,
        );
      case 'broker':
        return StockRow(
          ticker: ticker,
          nse: nse,
          bse: bse,
          yahoo: yahoo,
          broker: StockSourceDetails(
            price: newPrice,
            timestamp: newTime,
            previousPrice: broker.price,
            lastFlashTime: now,
          ),
        );
      default:
        return this;
    }
  }
}
