import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() {
  runApp(const PosturaApp());
}

class PosturaApp extends StatelessWidget {
  const PosturaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monitorizare Postura',
      theme: ThemeData(primarySwatch: Colors.blue, brightness: Brightness.dark),
      home: const BluetoothScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class BluetoothScreen extends StatefulWidget {
  const BluetoothScreen({super.key});
  @override
  State<BluetoothScreen> createState() => _BluetoothScreenState();
}

class _BluetoothScreenState extends State<BluetoothScreen> {
  final String targetDeviceName = "ESP32_Postura";
  final Guid serviceUuid = Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
  final Guid characteristicUuid = Guid("beb5483e-36e1-4688-b7f5-ea07361b26a8");

  BluetoothDevice? espDevice;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  StreamSubscription<List<int>>? dataSubscription;
  Timer? _internalTimer; 

  // --- NOTIFICARI ---
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _hasNotifiedToStand = false; // Ne asigura ca suna o singura data pe sesiune

  bool isConnected = false;
  String connectionStatus = "Deconectat. Se cauta...";
  String rawData = "Asteptare date...";
  
  // Date extrase live
  double currentDistance = 0;
  bool isSitting = false;
  String currentPostureState = "OK"; 
  
  // Date pentru grafice
  List<FlSpot> distanceSpots = [];
  double timerX = 0;
  
  // Acumulatoare pentru Pie Chart si Bar Chart
  int totalSecondsSitting = 0;
  int totalSecondsStanding = 0;
  int posturaCorectaSec = 0;
  int posturaGresitaSec = 0;

  @override
  void initState() {
    super.initState();
    _initNotifications(); // Initializam sistemul de notificari
    _requestPermissionsAndStart();

    _internalTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!isConnected) return; 

      setState(() {
        if (isSitting) {
          totalSecondsSitting++;
          if (currentPostureState.contains("ATENTIE!") || currentPostureState.contains("POSTURA PROASTA!")) {
            posturaGresitaSec++;
          } else {
            posturaCorectaSec++;
          }
        } else {
          totalSecondsStanding++;
        }
      });
    });
  }

  // Setarile de baza pentru notificari pe Android
  void _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
    await flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  // Forteaza notificarea sa apara pe ecran (Heads-Up)
  Future<void> _showStandUpNotification() async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'stand_up_channel', // ID Canal
      'Alerte Pauza', // Numele in setari
      channelDescription: 'Te anunta cand trebuie sa te ridici',
      importance: Importance.max, // MAX forteaza aparitia peste aplicatie!
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    );
    const NotificationDetails platformDetails = NotificationDetails(android: androidDetails);
    
    await flutterLocalNotificationsPlugin.show(
      0,
      'Timpul a expirat!',
      'Ai stat mult pe scaun!',
      platformDetails,
    );
  }

  Future<void> _requestPermissionsAndStart() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.notification, // Cerem acces si la notificari!
    ].request();

    _startScan();
  }

  void _startScan() {
    setState(() => connectionStatus = "Scanez dupa $targetDeviceName...");
    
    scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult result in results) {
        if (result.device.platformName == targetDeviceName) {
          FlutterBluePlus.stopScan();
          _connectToDevice(result.device);
          break;
        }
      }
    });
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() {
      espDevice = device;
      connectionStatus = "Conectare la ESP32...";
    });

    try {
      await device.disconnect(); 
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 7), license: License.free);
      
      setState(() {
        connectionStatus = "Conectat! Cautam servicii...";
        isConnected = true;
      });
      _discoverServices(device);
    } catch (e) {
      setState(() {
        connectionStatus = "Eroare conectare: $e";
        isConnected = false;
      });
    }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid == serviceUuid) {
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          if (characteristic.uuid == characteristicUuid) {
            _subscribeToData(characteristic);
            return;
          }
        }
      }
    }
  }

  void _subscribeToData(BluetoothCharacteristic characteristic) async {
    await characteristic.setNotifyValue(true);
    setState(() => connectionStatus = "Primim date in timp real!");

    dataSubscription = characteristic.lastValueStream.listen((value) {
      String decodedData = utf8.decode(value);
      _parseIncomingData(decodedData);
    });
  }

  void _parseIncomingData(String data) {
    setState(() {
      rawData = data;

      // 1. Extragem Distanta
      RegExp distRegex = RegExp(r'Dist: (\d+)cm');
      var distMatch = distRegex.firstMatch(data);
      if (distMatch != null) {
        currentDistance = double.parse(distMatch.group(1)!);
        distanceSpots.add(FlSpot(timerX, currentDistance));
        if (distanceSpots.length > 20) distanceSpots.removeAt(0);
      }

      // 2. Extragem starea de scaun si timpul exact pentru notificare
      RegExp asezatRegex = RegExp(r'ASEZAT \((\d+)s\)');
      var asezatMatch = asezatRegex.firstMatch(data);

      if (asezatMatch != null) {
        isSitting = true;
        int consecutiveSittingSec = int.parse(asezatMatch.group(1)!);
        
        // Magia: daca treci de 50 de secunde, arunca notificarea
        if (consecutiveSittingSec >= 50 && !_hasNotifiedToStand) {
          _showStandUpNotification();
          _hasNotifiedToStand = true; // Nu il mai spamam pana nu se ridica
        }
      } else if (data.contains("PLECAT")) {
        isSitting = false;
        _hasNotifiedToStand = false; // Te-ai ridicat, resetam sistemul de notificare
      }

      // 3. Extragem starea exacta a posturii 
      if (data.contains("POSTURA PROASTA!")) {
        currentPostureState = "POSTURA PROASTA!";
      } else if (data.contains("ATENTIE!")) {
        currentPostureState = "ATENTIE!";
      } else {
        currentPostureState = "OK";
      }

      timerX++;
    });
  }

  String formatTime(int totalSeconds) {
    int h = totalSeconds ~/ 3600;
    int m = (totalSeconds % 3600) ~/ 60;
    int s = totalSeconds % 60;
    
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s'; 
  }

  @override
  void dispose() {
    scanSubscription?.cancel();
    dataSubscription?.cancel();
    _internalTimer?.cancel();
    espDevice?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double maxBarY = (totalSecondsSitting > totalSecondsStanding ? totalSecondsSitting : totalSecondsStanding).toDouble();
    if (maxBarY < 10) maxBarY = 10; 

    return Scaffold(
      appBar: AppBar(title: const Text('Postura IoT Dashboard')),
      body: isConnected == false 
      ? Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text(connectionStatus, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            ],
          ),
        )
      : SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text("Primim date in timp real!", style: TextStyle(fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              ),
              const SizedBox(height: 10),
              
              Text(rawData, style: const TextStyle(fontSize: 14, fontFamily: 'monospace'), textAlign: TextAlign.center, overflow: TextOverflow.fade),
              const SizedBox(height: 20),

              // ================= GRAFIC 1 =================
              const Text("Distanta Postura (cm)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              SizedBox(
                height: 150, 
                child: distanceSpots.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : LineChart(
                        LineChartData(
                          clipData: const FlClipData.all(),
                          minY: 0,
                          maxY: 100, 
                          lineBarsData: [
                            LineChartBarData(
                              spots: distanceSpots,
                              isCurved: true,
                              color: Colors.blueAccent,
                              barWidth: 4,
                              isStrokeCapRound: true,
                              dotData: const FlDotData(show: false),
                              belowBarData: BarAreaData(show: true, color: Colors.blueAccent.withValues(alpha: 0.3)),
                            ),
                          ],
                          titlesData: const FlTitlesData(
                            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 30),

              // ================= GRAFIC 2 =================
              const Text("Analiza Posturii (Asezat)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              SizedBox(
                height: 200,
                child: (posturaCorectaSec == 0 && posturaGresitaSec == 0)
                  ? const Center(child: Text("Asteptam sa te asezi pe scaun..."))
                  : PieChart(
                      PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 50,
                        sections: [
                          PieChartSectionData(
                            color: Colors.greenAccent,
                            value: posturaCorectaSec > 0 ? posturaCorectaSec.toDouble() : 0.1,
                            title: formatTime(posturaCorectaSec),
                            radius: 40,
                            titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          PieChartSectionData(
                            color: Colors.redAccent,
                            value: posturaGresitaSec > 0 ? posturaGresitaSec.toDouble() : 0.1,
                            title: formatTime(posturaGresitaSec),
                            radius: 40,
                            titleStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(width: 12, height: 12, color: Colors.greenAccent), const SizedBox(width: 4), const Text("Corecta"),
                  const SizedBox(width: 20),
                  Container(width: 12, height: 12, color: Colors.redAccent), const SizedBox(width: 4), const Text("Gresita"),
                ],
              ),
              const SizedBox(height: 30),

              // STATUS CURENT
              Center(
                child: Text(
                  "STATUS CURENT: ${isSitting ? 'ASEZAT' : 'RIDICAT'}", 
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isSitting ? Colors.blueAccent : Colors.orangeAccent)
                ),
              ),
              const SizedBox(height: 30),

              // ================= GRAFIC 3 =================
              const Text("Activitate Zilnica", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              SizedBox(
                height: 220,
                child: BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround, 
                    maxY: maxBarY + (maxBarY * 0.25), 
                    
                    barTouchData: BarTouchData(
                      enabled: false, 
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (group) => Colors.transparent, 
                        tooltipPadding: EdgeInsets.zero,
                        tooltipMargin: 8, 
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          return BarTooltipItem(
                            formatTime(rod.toY.toInt()), 
                            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          );
                        },
                      ),
                    ),
                    barGroups: [
                      BarChartGroupData(
                        x: 0,
                        barRods: [
                          BarChartRodData(
                            toY: totalSecondsSitting.toDouble(),
                            color: Colors.blueAccent,
                            width: 35, 
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ],
                        showingTooltipIndicators: [0], 
                      ),
                      BarChartGroupData(
                        x: 1,
                        barRods: [
                          BarChartRodData(
                            toY: totalSecondsStanding.toDouble(),
                            color: Colors.orangeAccent,
                            width: 35, 
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ],
                        showingTooltipIndicators: [0], 
                      ),
                    ],
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (double value, TitleMeta meta) {
                            if (value == 0) return const Padding(padding: EdgeInsets.only(top: 8.0), child: Text('Asezat', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70)));
                            if (value == 1) return const Padding(padding: EdgeInsets.only(top: 8.0), child: Text('Ridicat', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70)));
                            return const Text('');
                          },
                        ),
                      ),
                    ),
                    gridData: const FlGridData(show: false), 
                    borderData: FlBorderData(show: false), 
                  ),
                ),
              ),
              const SizedBox(height: 40), 
            ],
          ),
        ),
      ),
    );
  }
}