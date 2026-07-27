import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../models/stock_models.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final String _serverUrl;
  IO.Socket? _socket;
  bool _isConnected = false;
  String? _errorMessage;

  // Stock rows mapping
  final Map<String, StockRow> _stocksMap = {};
  List<String> _tickersOrder = [];
  
  // Console logs
  final List<String> _consoleLogs = [];
  final ScrollController _consoleScrollController = ScrollController();

  // Metrics trackers
  int _totalUpdatesReceived = 0;
  int _updatesPerSecond = 0;
  int _ticksThisSecond = 0;
  Timer? _fpsTimer;
  Timer? _flashCleanupTimer;

  @override
  void initState() {
    super.initState();
    // Default server url based on platform
    _serverUrl = kIsWeb ? 'http://localhost:3001' : 'http://10.0.2.2:3001';
    
    _initializeDataAndSockets();

    // Calculate updates per second
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _updatesPerSecond = _ticksThisSecond;
        _ticksThisSecond = 0;
      });
    });

    // Periodic rebuild to refresh/fade the cell highlight colors
    _flashCleanupTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (mounted && _stocksMap.isNotEmpty) {
        setState(() {}); // Trigger refresh so that faded backgrounds recalculate opacity
      }
    });
  }

  @override
  void dispose() {
    _fpsTimer?.cancel();
    _flashCleanupTimer?.cancel();
    _socket?.disconnect();
    _socket?.destroy();
    _consoleScrollController.dispose();
    super.dispose();
  }

  // Load initial grid stats and connect websocket
  Future<void> _initializeDataAndSockets() async {
    setState(() {
      _errorMessage = null;
    });

    try {
      // 1. Initial REST API load
      final response = await http.get(Uri.parse('$_serverUrl/api/stocks'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        _tickersOrder.clear();
        for (var json in data) {
          final row = StockRow.fromJson(json);
          _stocksMap[row.ticker] = row;
          _tickersOrder.add(row.ticker);
        }
      } else {
        throw Exception('API Server returned status code: ${response.statusCode}');
      }

      // 2. Connect to Socket.io
      _socket = IO.io(
        _serverUrl,
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .disableAutoConnect()
            .build(),
      );

      _socket!.onConnect((_) {
        setState(() {
          _isConnected = true;
        });
        _addConsoleLog('Connected to Real-Time WebSockets Stock Feed server.');
      });

      _socket!.onDisconnect((_) {
        setState(() {
          _isConnected = false;
        });
        _addConsoleLog('Disconnected from Stock Feed server.');
      });

      // Handle live price updates
      _socket!.on('stock-update', (data) {
        if (data == null) return;
        final String ticker = data['ticker'] ?? '';
        final String source = data['source'] ?? '';
        final double price = data['price'] is num 
            ? (data['price'] as num).toDouble() 
            : double.parse(data['price'].toString());
        final DateTime timestamp = data['timestamp'] != null 
            ? DateTime.parse(data['timestamp']).toLocal() 
            : DateTime.now();

        if (_stocksMap.containsKey(ticker)) {
          setState(() {
            final oldRow = _stocksMap[ticker]!;
            final newRow = oldRow.copyWithSource(source, price, timestamp);
            _stocksMap[ticker] = newRow;

            _totalUpdatesReceived++;
            _ticksThisSecond++;
          });

          // Add message to scroll console
          final timeStr = DateFormat('HH:mm:ss.SSS').format(timestamp);
          final diffInfo = _calculateArbitrageWarning(ticker, source, price);
          _addConsoleLog('[$timeStr] $ticker updated on ${source.toUpperCase()} to $price$diffInfo');
        }
      });

      _socket!.connect();

    } catch (e) {
      setState(() {
        _errorMessage = 'Initialization Error: ${e.toString().replaceFirst('Exception: ', '')}';
      });
      _addConsoleLog('Error initializing connection: $e');
    }
  }

  // Calculate percentage difference relative to other sources
  String _calculateArbitrageWarning(String ticker, String updatedSource, double newPrice) {
    final row = _stocksMap[ticker];
    if (row == null) return '';
    
    // Find average of other sources
    double sum = 0.0;
    int count = 0;
    if (updatedSource != 'nse' && row.nse.price > 0) { sum += row.nse.price; count++; }
    if (updatedSource != 'bse' && row.bse.price > 0) { sum += row.bse.price; count++; }
    if (updatedSource != 'yahoo' && row.yahoo.price > 0) { sum += row.yahoo.price; count++; }
    if (updatedSource != 'broker' && row.broker.price > 0) { sum += row.broker.price; count++; }

    if (count == 0) return '';
    final avgOther = sum / count;
    final diffPercent = ((newPrice - avgOther) / avgOther) * 100;
    
    if (diffPercent.abs() > 0.08) {
      return ' (Diff vs. others: ${diffPercent > 0 ? '+' : ''}${diffPercent.toStringAsFixed(2)}%) ⚠️ Arbitrage Opportunity';
    }
    return '';
  }

  // Append logs to console box
  void _addConsoleLog(String message) {
    if (!mounted) return;
    setState(() {
      _consoleLogs.add(message);
      if (_consoleLogs.length > 50) {
        _consoleLogs.removeAt(0);
      }
    });
    // Auto-scroll console
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_consoleScrollController.hasClients) {
        _consoleScrollController.jumpTo(_consoleScrollController.position.maxScrollExtent);
      }
    });
  }

  // Calculate Summary metrics
  double _calculateAveragePrice() {
    if (_stocksMap.isEmpty) return 0.0;
    double sum = 0.0;
    _stocksMap.forEach((ticker, row) {
      sum += row.nse.price; // Use NSE as standard benchmark
    });
    return sum / _stocksMap.length;
  }

  String _calculateTopGainer() {
    if (_stocksMap.isEmpty) return 'N/A';
    String bestTicker = 'N/A';
    double maxChangePct = -999.0;
    
    _stocksMap.forEach((ticker, row) {
      if (row.nse.previousPrice != null && row.nse.previousPrice! > 0) {
        final change = ((row.nse.price - row.nse.previousPrice!) / row.nse.previousPrice!) * 100;
        if (change > maxChangePct) {
          maxChangePct = change;
          bestTicker = '$ticker (${change > 0 ? '+' : ''}${change.toStringAsFixed(2)}%)';
        }
      }
    });
    return bestTicker == 'N/A' ? 'RELIANCE' : bestTicker;
  }

  // Helper colors for flash animation
  Color _getCellFlashColor(StockSourceDetails details) {
    if (details.lastFlashTime == null || details.previousPrice == null) {
      return Colors.transparent;
    }
    final now = DateTime.now();
    final difference = now.difference(details.lastFlashTime!);
    
    // Keep flash active for 400 milliseconds
    const flashDuration = 400;
    if (difference.inMilliseconds > flashDuration) {
      return Colors.transparent;
    }

    // Fading effect
    final double opacity = (1.0 - (difference.inMilliseconds / flashDuration)).clamp(0.0, 1.0);
    
    if (details.price > details.previousPrice!) {
      return Colors.greenAccent.withOpacity(0.20 * opacity);
    } else if (details.price < details.previousPrice!) {
      return Colors.redAccent.withOpacity(0.20 * opacity);
    }
    return Colors.transparent;
  }

  // Price direction arrow or color indicator
  Color _getPriceColor(StockSourceDetails details) {
    if (details.previousPrice == null || details.price == details.previousPrice) {
      return Colors.white70;
    }
    return details.price > details.previousPrice! ? Colors.greenAccent : Colors.redAccent;
  }

  IconData _getPriceIcon(StockSourceDetails details) {
    if (details.previousPrice == null || details.price == details.previousPrice) {
      return Icons.minimize_rounded;
    }
    return details.price > details.previousPrice! 
        ? Icons.trending_up_rounded 
        : Icons.trending_down_rounded;
  }

  Widget _buildSummaryCard(String title, String value, IconData icon, Color accentColor) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
        padding: const EdgeInsets.all(18.0),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1A3C) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.05) : Colors.purple.withOpacity(0.1),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.2 : 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: accentColor.withOpacity(0.12),
              child: Icon(icon, color: accentColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 18, 
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = size.width < 750;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blueAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.analytics_rounded, color: Colors.blueAccent, size: 20),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Multi-Source Price Aggregator',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                Text('Real-Time Live LTP Comparison Grid', style: TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _isConnected ? Colors.green.withOpacity(0.15) : Colors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _isConnected ? Colors.greenAccent.withOpacity(0.3) : Colors.redAccent.withOpacity(0.3),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _isConnected ? 'WS CONNECTED' : 'DISCONNECTED',
                  style: TextStyle(
                    color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          )
        ],
      ),
      body: _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.cloud_off_rounded, size: 64, color: Colors.redAccent),
                  const SizedBox(height: 16),
                  Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent, fontSize: 16)),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _initializeDataAndSockets,
                    child: const Text('Retry Connection'),
                  ),
                ],
              ),
            )
          : _stocksMap.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      // Summary Cards (Vertical scroll on mobile, side-by-side on Web)
                      if (!isMobile) ...[
                        Row(
                          children: [
                            _buildSummaryCard(
                              'AVG PRICE (NSE)', 
                              '₹${_calculateAveragePrice().toStringAsFixed(2)}', 
                              Icons.insights_rounded, 
                              Colors.purpleAccent
                            ),
                            _buildSummaryCard(
                              'TOP GAINER (NSE)', 
                              _calculateTopGainer(), 
                              Icons.trending_up_rounded, 
                              Colors.greenAccent
                            ),
                            _buildSummaryCard(
                              'TICK FREQUENCY', 
                              '$_updatesPerSecond upd/sec', 
                              Icons.bolt_rounded, 
                              Colors.amberAccent
                            ),
                            _buildSummaryCard(
                              'TOTAL VOLUMES RECEIVED', 
                              '$_totalUpdatesReceived ticks', 
                              Icons.query_stats_rounded, 
                              Colors.blueAccent
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ] else ...[
                        SizedBox(
                          height: 90,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              SizedBox(
                                width: 200,
                                child: _buildSummaryCard('AVG PRICE (NSE)', '₹${_calculateAveragePrice().toStringAsFixed(2)}', Icons.insights_rounded, Colors.purpleAccent),
                              ),
                              SizedBox(
                                width: 220,
                                child: _buildSummaryCard('TOP GAINER (NSE)', _calculateTopGainer(), Icons.trending_up_rounded, Colors.greenAccent),
                              ),
                              SizedBox(
                                width: 200,
                                child: _buildSummaryCard('FEED FREQUENCY', '$_updatesPerSecond updates/s', Icons.bolt_rounded, Colors.amberAccent),
                              ),
                              SizedBox(
                                width: 200,
                                child: _buildSummaryCard('TOTAL TICK VOL', '$_totalUpdatesReceived ticks', Icons.query_stats_rounded, Colors.blueAccent),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Grid Data Table (Wrapped in horizontal scrolling to ensure full columns display clearly on mobile devices)
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF110E23) : const Color(0xFFF1EEF6),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: isDark ? Colors.white.withOpacity(0.06) : Colors.black12),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.vertical,
                                child: DataTable(
                                  columnSpacing: size.width > 1200 ? 55 : 32,
                                  headingRowColor: WidgetStateProperty.all(isDark ? const Color(0xFF1E1A3C) : const Color(0xFFE4DFEC)),
                                  columns: const [
                                    DataColumn(label: Text('STOCK TICKER', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('NSE LTP', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('BSE LTP', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('YAHOO FINANCE LTP', style: TextStyle(fontWeight: FontWeight.bold))),
                                    DataColumn(label: Text('BROKER LTP (LTP)', style: TextStyle(fontWeight: FontWeight.bold))),
                                  ],
                                  rows: _tickersOrder.map((ticker) {
                                    final row = _stocksMap[ticker]!;
                                    
                                    DataCell buildGridCell(StockSourceDetails details) {
                                      final flashBgColor = _getCellFlashColor(details);
                                      final priceColor = _getPriceColor(details);
                                      final icon = _getPriceIcon(details);
                                      final timeStr = DateFormat('HH:mm:ss').format(details.timestamp);

                                      return DataCell(
                                        AnimatedContainer(
                                          duration: const Duration(milliseconds: 100),
                                          color: flashBgColor,
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                          alignment: Alignment.centerLeft,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(icon, size: 14, color: priceColor),
                                              const SizedBox(width: 6),
                                              Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Text(
                                                    '₹${details.price.toStringAsFixed(2)}',
                                                    style: TextStyle(
                                                      fontWeight: FontWeight.bold,
                                                      color: priceColor,
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                  Text(
                                                    timeStr,
                                                    style: const TextStyle(
                                                      fontSize: 9, 
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    }

                                    return DataRow(
                                      cells: [
                                        DataCell(
                                          Row(
                                            children: [
                                              const Icon(Icons.show_chart_rounded, size: 16, color: Colors.blueAccent),
                                              const SizedBox(width: 10),
                                              Text(
                                                row.ticker,
                                                style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
                                              ),
                                            ],
                                          ),
                                        ),
                                        buildGridCell(row.nse),
                                        buildGridCell(row.bse),
                                        buildGridCell(row.yahoo),
                                        buildGridCell(row.broker),
                                      ],
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 16),

                      // Monospace Log Console Panel
                      Container(
                        height: 160,
                        width: double.infinity,
                        padding: const EdgeInsets.all(12.0),
                        decoration: BoxDecoration(
                          color: const Color(0xFF040209),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.08)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: Colors.greenAccent,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'REAL-TIME SOCKET FEED LOGGER',
                                      style: TextStyle(
                                        fontFamily: 'Courier', 
                                        fontSize: 11, 
                                        color: Colors.greenAccent,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  'SPEED: $_updatesPerSecond/s',
                                  style: const TextStyle(fontFamily: 'Courier', fontSize: 10, color: Colors.white60),
                                )
                              ],
                            ),
                            const Divider(color: Colors.white24, height: 12),
                            Expanded(
                              child: _consoleLogs.isEmpty
                                  ? const Center(
                                      child: Text(
                                        'Awaiting websocket stream events...',
                                        style: TextStyle(fontFamily: 'Courier', color: Colors.grey, fontSize: 12),
                                      ),
                                    )
                                  : ListView.builder(
                                      controller: _consoleScrollController,
                                      itemCount: _consoleLogs.length,
                                      itemBuilder: (context, index) {
                                        final log = _consoleLogs[index];
                                        return Text(
                                          log,
                                          style: TextStyle(
                                            fontFamily: 'Courier', 
                                            color: log.contains('Arbitrage') ? Colors.amberAccent : Colors.white70,
                                            fontSize: 11,
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      )
                    ],
                  ),
                ),
    );
  }
}
