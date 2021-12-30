import 'dart:math';

import 'package:covid_checker/certs/certs.dart';
import 'package:covid_checker/models/result.dart';
import 'package:covid_checker/utils/base45.dart';
import 'package:covid_checker/utils/gen_swatch.dart';
import 'package:covid_checker/widgets/cert_simplified_view.dart';
import 'package:covid_checker/widgets/logo.dart';
import 'package:dart_cose/dart_cose.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:honeywell_scanner/honeywell_scanner.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'generated/l10n.dart';

import "package:covid_checker/utils/gzip/gzip_decode_stub.dart" // Version which just throws UnsupportedError
    if (dart.library.io) "package:covid_checker/utils/gzip/gzip_decode_io.dart"
    if (dart.library.js) "package:covid_checker/utils/gzip/gzip_decode_js.dart";

void main() {
  runApp(const CovCheckApp());
}

class CovCheckApp extends StatelessWidget {
  const CovCheckApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: S.delegate.supportedLocales,
      title: 'CovCheck',
      theme: ThemeData(
        primarySwatch: createMaterialColor(const Color(0xFF262DC9)),
        primaryColor: const Color(0xFF262DC9),
        backgroundColor: const Color(0xffECEEFF),
      ),
      darkTheme: ThemeData.dark().copyWith(
        backgroundColor: const Color(0xff080B27),
        cardColor: const Color(0xff050612),
        primaryColor: const Color(0xFF262DC9),
        primaryColorDark: const Color(0xFF262DC9),
      ),
      home: const MyHomePage(title: 'CovCheck'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage>
    with WidgetsBindingObserver
    implements ScannerCallBack {
  HoneywellScanner honeywellScanner = HoneywellScanner();

  @override
  void onDecoded(String? code) {
    dismissResults();
    List<int> scanres = [];
    try {
      /// Decode the base 45 data after removing the HC1: prefix
      scanres = Base45.decode(code!.replaceAll("HC1:", ""));
      /// Decode the gzip data which was decoded from the base45 string
      scanres = gzipDecode(scanres);
      /// Pass the data onto the Cose decoder where it will match it to a certificate (if valid)
      var cose = Cose.decodeAndVerify(scanres, certMap);
      setState(() {
        /// Update the state and set cose and scanData
        coseResult = cose;
        scanres = scanres;

        /// Process payload from cose and extract the data
        processedResult = Result.fromDGC(cose.payload);
      });
    } catch (e) {
      setState(() {
        coseResult = CoseResult(
            payload: {},
            verified: false,
            errorCode: CoseErrorCode.invalid_format,
            certificate: null);
        scanres = scanres;
        processedResult = null;
      });
    }
  }

  @override
  void onError(Exception error) {
    dismissResults();
  }

  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');

  /// Barcode Result will store the raw data and type of Barcode which has been scanned
  /// We are expecting a QR code, which starts with HC1
  Barcode? result;

  /// After successfull decoding, COSE Result will be populated with a valid certificate
  /// and the payload contained in the QR Code, processed and ready for the data
  /// to be extracted.
  CoseResult? coseResult;

  /// On InitState we need to convert the raw ceritificates into a map where the keys are
  /// KIDs and the x5c certificates are the value, will be used to verify ceritificate authenticity
  Map<String, String> certMap = {};

  /// Processed Result will store all of the data in a easy-to-use model, ready for viewing within the app
  Result? processedResult;

  /// Store if we should show the snackbar, only on web
  bool isWarningDismissed = false;

  /// Honeywell scanner params
  bool scannerEnabled = false;
  bool scan1DFormats = false;
  bool scan2DFormats = true;
  bool isDeviceSupported = false;

  @override
  void initState() {
    /// Cycle through all of the certificates and extract the KID and X5C values, mapping them into certMap.
    /// This is a relatively expensive process so should be run as little as possible.
    (certs["dsc_trust_list"] as Map).forEach((key, value) {
      for (var element in (value["keys"] as List)) {
        certMap[element["kid"]] = element["x5c"][0];
      }
    });
    WidgetsBinding.instance?.addObserver(this);
    honeywellScanner.setScannerCallBack(this);
    init();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    /// Get MediaQuery for size & orientation. Used for layout
    MediaQueryData mq = MediaQuery.of(context);

    /// Orientation from mediaquery
    Orientation orientation = mq.orientation;

    /// Size from mediaquery
    Size size = mq.size;

    /// Main widget Stack, it is in a separtate varialble to make lasyouts much easier
    final widgetList = <Widget>[
      /// Logo will only be shown if in portrait, dunno whe it can go in landsacpe
      if (orientation == Orientation.portrait) const Logo(),
      /// Details Section
      Expanded(
          flex: 1,
          child: Padding(
            padding: orientation == Orientation.portrait
                ? EdgeInsets.zero
                : const EdgeInsets.only(right: 10),
            child: CertSimplifiedView(
              coseResult: coseResult,
              //barcodeResult: result,
              dismiss: dismissResults,
              processedResult: processedResult,
            ),
          )),
    ];

    /// UI declaration
    return Scaffold(
      backgroundColor: Theme.of(context).backgroundColor,
      body: SafeArea(
        child: MediaQuery.of(context).orientation == Orientation.landscape

            /// If landscape then set out in a Row (Camera) (Details)
            ? Row(
                children: widgetList,
              )

            /// If porrtait set out in column
            /// (Camera)
            /// (Details)
            : Column(
                children: widgetList,
              ),
      ),
    );
  }

  /// Utility function so that the dismissal clears the card
  void dismissResults() {
    setState(() {
      coseResult = null;
      result = null;
      processedResult = null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        honeywellScanner.resumeScanner();
        break;
      case AppLifecycleState.inactive:
        honeywellScanner.pauseScanner();
        break;
      case AppLifecycleState
          .paused: //AppLifecycleState.paused is used as stopped state because deactivate() works more as a pause for lifecycle
        honeywellScanner.pauseScanner();
        break;
      case AppLifecycleState.detached:
        honeywellScanner.pauseScanner();
        break;
      default:
        break;
    }
  }

  Future<void> init() async {
    updateScanProperties();
    isDeviceSupported = await honeywellScanner.isSupported();
    await honeywellScanner.startScanner();
    if (mounted) setState(() {});
  }

  void updateScanProperties() {
    List<CodeFormat> codeFormats = [];
    if (scan1DFormats) codeFormats.addAll(CodeFormatUtils.ALL_1D_FORMATS);
    if (scan2DFormats) codeFormats.addAll(CodeFormatUtils.ALL_2D_FORMATS);

//    codeFormats.add(CodeFormat.AZTEC);
//    codeFormats.add(CodeFormat.CODABAR);
//    codeFormats.add(CodeFormat.CODE_39);
//    codeFormats.add(CodeFormat.CODE_93);
//    codeFormats.add(CodeFormat.CODE_128);
//    codeFormats.add(CodeFormat.DATA_MATRIX);
//    codeFormats.add(CodeFormat.EAN_8);
//    codeFormats.add(CodeFormat.EAN_13);
//    codeFormats.add(CodeFormat.ITF);
//    codeFormats.add(CodeFormat.MAXICODE);
//    codeFormats.add(CodeFormat.PDF_417);
//    codeFormats.add(CodeFormat.QR_CODE);
//    codeFormats.add(CodeFormat.RSS_14);
//    codeFormats.add(CodeFormat.RSS_EXPANDED);
//    codeFormats.add(CodeFormat.UPC_A);
//    codeFormats.add(CodeFormat.UPC_E);
////    codeFormats.add(CodeFormat.UPC_EAN_EXTENSION);
    Map<String, dynamic> properties = {
      ...CodeFormatUtils.getAsPropertiesComplement(codeFormats),
      'DEC_CODABAR_START_STOP_TRANSMIT': true,
      'DEC_EAN13_CHECK_DIGIT_TRANSMIT': true,
    };
    honeywellScanner.setProperties(properties);
  }

  /// When disposing, get rid of the QR Code controller too.
  @override
  void dispose() {
    honeywellScanner.stopScanner();
    super.dispose();
  }
}
