import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'models/inventory_item.dart';
import 'models/order.dart' as myorder;
import 'services/user_service.dart';
import 'services/inventory_service.dart';
import 'services/order_service.dart';
import 'widgets/topup_dialog.dart';
import 'widgets/shop_dashboard_page.dart';
import 'widgets/home_content.dart';
import 'widgets/shop_cart_dialog.dart';
import 'widgets/map_content.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'widgets/profile_content.dart';
import 'package:geolocator/geolocator.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // --- State ---
  String affirmation = "Kata Penyemangat";
  String? name;
  String? username;
  List<InventoryItem> _shopItems = [];
  double? _balance;
  List<InventoryItem> _cartItems = [];
  List<myorder.Order> _orderHistory = [];
  bool _isLoading = true;

  // Tambahkan state untuk konversi mata uang
  String _selectedCurrency = 'IDR';
  final Map<String, String> _currencySymbols = {
    'IDR': 'Rp',
    'USD': '\$',
    'EUR': 'EUR',
    'GBP': '£',
  };
  final Map<String, double> _currencyRates = {
    'IDR': 1.0,
    'USD': 0.000065, // 1 IDR = 0.000065 USD (contoh, update sesuai kurs terbaru)
    'EUR': 0.000060, // 1 IDR = 0.000060 EUR
    'GBP': 0.000051, // 1 IDR = 0.000051 GBP
  };

  int _selectedIndex = 0;

  // State untuk Map
  final LatLng _defaultCenter = LatLng(-7.7691672922501915, 110.40738797582647);
  LatLng? _currentPosition;
  late final MapController _mapController = MapController();
  double _currentZoom = 16.0;
  bool _gettingLocation = false;

  // Daftar marker statis rumah billiard
  final List<Map<String, dynamic>> _billiardMarkers = [
    {
      'name': 'Five Seven',
      'point': LatLng(-7.770281152797553, 110.40488150682984),
    },
    {
      'name': 'Simple Chapter 07',
      'point': LatLng(-7.774830907152643, 110.40393736945487),
    },
    {
      'name': 'The Gardens',
      'point': LatLng(-7.772449733457909, 110.40844348051856),
    },
    {
      'name': 'Zon Billiard',
      'point': LatLng(-7.773215112242821, 110.41007426371505),
    },
  ];

  @override
  void initState() {
    super.initState();
    fetchAffirmation();
    _loadUserData();
    _loadInventory();
  }

  Future<void> fetchAffirmation() async {
    try {
      final response = await http.get(Uri.parse('https://katanime.vercel.app/api/getrandom'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final String kata = data['result'][0]['indo'] ?? affirmation;
        setState(() {
          affirmation = kata;
        });
      }
    } catch (e) {
      // ignore error, keep default affirmation
    }
  }

  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    username = prefs.getString('username');
    if (username != null) {
      final user = await UserService.getUserByUsername(username!);
      // MIGRASI: Jika user belum punya field balance, tambahkan ke Firestore
      if (user != null && user.balance == 0) {
        final doc = await FirebaseFirestore.instance.collection('users').doc(username).get();
        if (!doc.data()!.containsKey('balance')) {
          await FirebaseFirestore.instance.collection('users').doc(username).update({'balance': 0.0});
        }
      }
      setState(() {
        name = user?.name ?? 'User';
        _balance = user?.balance ?? 0;
      });
      _loadOrderHistory();
    }
  }

  Future<void> _loadInventory() async {
    setState(() { _isLoading = true; });
    final items = await InventoryService.getAllItems();
    setState(() {
      _shopItems = items;
      _isLoading = false;
    });
  }

  Future<void> _updateBalance(double newBalance) async {
    if (username == null) return;
    final user = await UserService.getUserByUsername(username!);
    if (user != null) {
      user.balance = newBalance;
      await UserService.saveUser(user);
      setState(() {
        _balance = newBalance;
      });
    }
  }

  Future<void> _loadOrderHistory() async {
    if (username == null) return;
    final orders = await OrderService.getOrderHistory(username!);
    setState(() {
      _orderHistory = orders;
    });
  }

  Future<void> _saveOrderHistory() async {
    if (username == null) return;
    await OrderService.saveOrderHistory(username!, _orderHistory);
  }

  void _showTopUpDialog() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => TopUpDialog(
        controller: controller,
        onTopUp: () async {
          final value = double.tryParse(controller.text) ?? 0;
          if (value > 0) {
            await _updateBalance((_balance ?? 0) + value);
            if (!mounted) return;
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Top up berhasil! Saldo bertambah Rp$value')),
            );
          }
        },
      ),
    );
  }

  double get _cartTotal => _cartItems.fold(0, (sum, item) => sum + (item.harga * item.jumlah));

  Future<void> _checkoutCart() async {
    if (_cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keranjang kosong!')),
      );
      return;
    }
    if ((_balance ?? 0) < _cartTotal) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saldo tidak cukup untuk checkout!')),
      );
      return;
    }
    // Cek stok cukup
    bool stokCukup = true;
    for (final cart in _cartItems) {
      final idx = _shopItems.indexWhere((e) => e.kode == cart.kode);
      if (idx == -1 || _shopItems[idx].jumlah < cart.jumlah) {
        stokCukup = false;
        break;
      }
    }
    if (!stokCukup) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Stok tidak cukup untuk salah satu barang!')),
      );
      return;
    }
    // Kurangi stok dan update Firestore
    for (final cart in _cartItems) {
      final idx = _shopItems.indexWhere((e) => e.kode == cart.kode);
      if (idx != -1) {
        final updated = _shopItems[idx].copyWith(jumlah: _shopItems[idx].jumlah - cart.jumlah);
        _shopItems[idx] = updated;
        await InventoryService.updateItem(updated);
      }
    }
    // Update saldo customer
    await _updateBalance((_balance ?? 0) - _cartTotal);
    // Update saldo pengusaha untuk setiap barang
    for (final cart in _cartItems) {
      final ownerUsername = cart.ownerUsername;
      final owner = await UserService.getUserByUsername(ownerUsername);
      if (owner != null) {
        owner.balance += cart.harga * cart.jumlah;
        await UserService.saveUser(owner);
      }
    }
    // Simpan ke riwayat pesanan
    final order = myorder.Order(
      items: _cartItems.map((e) => {
        'nama': e.nama,
        'kode': e.kode,
        'qty': e.jumlah,
        'harga': e.harga,
        'imagePath': e.imagePath,
        'ownerUsername': e.ownerUsername,
      }).toList(),
      total: _cartTotal,
      date: DateTime.now(),
    );
    setState(() {
      _orderHistory.insert(0, order);
      _cartItems.clear();
    });
    await _saveOrderHistory();
    // Update pengusaha order history and balance (jika ada global summary)
    await _updatePengusahaOrderHistoryAndBalance(order);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Checkout berhasil! Stok dan saldo terupdate.')),
    );
  }

  Future<void> _updatePengusahaOrderHistoryAndBalance(myorder.Order order) async {
    // Add to global order history and update pengusaha balance in Firestore
    await OrderService.addOrderToAll(order);
    // Find pengusaha user and update balance
    final pengusaha = await UserService.getPengusahaUser();
    if (pengusaha != null) {
      pengusaha.balance += order.total;
      await UserService.saveUser(pengusaha);
    }
  }

  // Menentukan nama rumah billiard terdekat
  String _getNearestBilliardName() {
    LatLng ref = _currentPosition ?? _defaultCenter;
    double minDist = double.infinity;
    String nearest = _billiardMarkers.first['name'];
    for (final marker in _billiardMarkers) {
      final LatLng point = marker['point'];
      final dist = Distance().as(LengthUnit.Kilometer, ref, point);
      if (dist < minDist) {
        minDist = dist;
        nearest = marker['name'];
      }
    }
    return nearest;
  }

  void _onNavBarTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
    if (index == 1) {
      // Tampilkan notifikasi saat buka tab Map
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final nearest = _getNearestBilliardName();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Halo $username, rumah billiard terdekat saat ini adalah $nearest'),
            duration: const Duration(seconds: 3),
          ),
        );
      });
    }
  }

  void _getCurrentLocation() async {
    setState(() { _gettingLocation = true; });
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await Geolocator.openLocationSettings();
        setState(() { _gettingLocation = false; });
        return;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() { _gettingLocation = false; });
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        setState(() { _gettingLocation = false; });
        return;
      }
      final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
        _gettingLocation = false;
      });
      _mapController.move(_currentPosition!, _currentZoom);
      // Tampilkan notifikasi rumah billiard terdekat setelah refresh lokasi
      if (mounted) {
        final nearest = _getNearestBilliardName();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('halo $username, rumah billiard terdekat saat ini adalah $nearest'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      setState(() { _gettingLocation = false; });
      // Bisa tampilkan snackbar error jika mau
    }
  }

  void _zoomIn() {
    setState(() { _currentZoom += 1; });
    _mapController.move(_currentPosition ?? _defaultCenter, _currentZoom);
  }
  void _zoomOut() {
    setState(() { _currentZoom -= 1; });
    _mapController.move(_currentPosition ?? _defaultCenter, _currentZoom);
  }

  @override
  Widget build(BuildContext context) {
    Widget bodyContent;
    if (_selectedIndex == 0) {
      if (_isLoading) {
        bodyContent = const Center(child: CircularProgressIndicator(color: Colors.white));
      } else {
        bodyContent = HomeContent(
          name: name,
          affirmation: affirmation,
          balance: _balance,
          selectedCurrency: _selectedCurrency,
          currencySymbols: _currencySymbols,
          currencyRates: _currencyRates,
          onShowTopUpDialog: _showTopUpDialog,
          onCurrencyChanged: (val) {
            if (val != null) setState(() => _selectedCurrency = val);
          },
          shopDashboard: const SizedBox.shrink(),
        );
      }
    } else if (_selectedIndex == 1) {
      bodyContent = MapContent(
        center: _defaultCenter,
        currentPosition: _currentPosition,
        mapController: _mapController,
        currentZoom: _currentZoom,
        gettingLocation: _gettingLocation,
        onGetCurrentLocation: _getCurrentLocation,
        onZoomIn: _zoomIn,
        onZoomOut: _zoomOut,
      );
    } else if (_selectedIndex == 2) {
      bodyContent = ShopDashboardPage(
        shopItems: _shopItems,
        balance: _balance,
        cartItems: _cartItems,
        onAddToCart: (int i) {
          setState(() {
            final item = _shopItems[i];
            final idx = _cartItems.indexWhere((e) => e.kode == item.kode);
            if (idx != -1) {
              _cartItems[idx].jumlah++;
            } else {
              _cartItems.add(InventoryItem(
                nama: item.nama,
                kode: item.kode,
                jumlah: 1,
                harga: item.harga,
                jenis: item.jenis,
                imagePath: item.imagePath ?? '',
                ownerUsername: item.ownerUsername,
              ));
            }
          });
        },
        onShowCartDialog: () {
          showDialog(
            context: context,
            builder: (context) => ShopCartDialog(
              cartItems: _cartItems.map((e) => {
                'nama': e.nama,
                'kode': e.kode,
                'qty': e.jumlah,
                'harga': e.harga,
                'imagePath': e.imagePath,
                'ownerUsername': e.ownerUsername,
              }).toList(),
              cartTotal: _cartTotal,
              onQtyChanged: (i, qty) {
                setState(() {
                  _cartItems[i].jumlah = qty;
                });
              },
              onRemove: (i) {
                setState(() {
                  _cartItems.removeAt(i);
                });
              },
              onCheckout: _checkoutCart,
            ),
          );
        },
      );
    } else if (_selectedIndex == 3) {
      bodyContent = const ProfileContent();
    } else {
      bodyContent = Container();
    }
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.black, Colors.grey[900]!, Colors.grey[800]!],
          ),
        ),
        child: SafeArea(child: bodyContent),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onNavBarTapped,
        selectedItemColor: Colors.blueAccent,
        unselectedItemColor: Colors.grey[500],
        backgroundColor: Colors.white,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.shopping_cart),
            label: 'Cart',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
