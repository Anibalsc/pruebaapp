 import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class JoseoSyncManager {
  JoseoSyncManager._();

  static final JoseoSyncManager instance = JoseoSyncManager._();

  static const String _pendingKey = 'pending_price_reports';
  static const String _photoBucket = 'price-evidence';

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _isSyncing = false;

  Future<void> start() async {
    await _subscription?.cancel();

    _subscription = Connectivity().onConnectivityChanged.listen(
      (results) async {
        final hasConnection =
            !results.contains(ConnectivityResult.none);

        if (hasConnection) {
          await checkPendingReports();
        }
      },
    );

    await checkPendingReports();
  }

  Future<void> checkPendingReports() async {
    await _syncPendingReports();
  }

  Future<bool> syncPendingReport(String reportId) async {
    return _syncPendingReports(targetReportId: reportId);
  }

  Future<bool> _syncPendingReports({String? targetReportId}) async {
    if (_isSyncing) return false;

    final client = Supabase.instance.client;
    final user = client.auth.currentUser;

    if (user == null) {
      return false;
    }

    _isSyncing = true;

    try {
      final preferences = await SharedPreferences.getInstance();
      final rawReports =
          preferences.getStringList(_pendingKey) ?? <String>[];

      if (rawReports.isEmpty) {
        return targetReportId == null;
      }

      debugPrint(
        'JOSEO: ${rawReports.length} precio(s) pendientes de sincronizar.',
      );

      final remaining = <String>[];
      var targetSynced = targetReportId == null;

      for (final rawReport in rawReports) {
        PendingPriceReport report;

        try {
          report = PendingPriceReport.fromJson(
            jsonDecode(rawReport) as Map<String, dynamic>,
          );
        } catch (error) {
          debugPrint('JOSEO: reporte local inválido: $error');
          remaining.add(rawReport);
          continue;
        }

        if (targetReportId != null && report.id != targetReportId) {
          remaining.add(rawReport);
          continue;
        }

        if (report.userId.isEmpty) {
          debugPrint(
            'JOSEO: ${report.id} es un pendiente antiguo sin usuario. Se conserva localmente.',
          );
          remaining.add(rawReport);
          continue;
        }

        if (report.userId != user.id) {
          // Nunca atribuimos a un usuario los pendientes de otra cuenta.
          remaining.add(rawReport);
          continue;
        }

        try {
          await _uploadReport(report, user.id);
          await _deleteLocalPhoto(report.photoPath);

          if (report.id == targetReportId) {
            targetSynced = true;
          }

          debugPrint('JOSEO: ${report.id} sincronizado correctamente.');
        } catch (error) {
          debugPrint(
            'JOSEO: ${report.id} sigue pendiente. Error de sincronización: $error',
          );
          remaining.add(rawReport);
        }
      }

      await preferences.setStringList(_pendingKey, remaining);
      return targetSynced;
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _uploadReport(
    PendingPriceReport report,
    String userId,
  ) async {
    final client = Supabase.instance.client;

    final productId = report.productId ??
        _legacyProductIdFromName(report.product);

    if (productId == null) {
      throw StateError(
        'No se pudo relacionar el producto "${report.product}" con Supabase.',
      );
    }

    int? branchId = report.branchId;

    if (branchId == null && !report.useGpsLocation) {
      branchId = _legacyBranchIdFromName(report.storeName);
    }

    if (branchId == null && report.useGpsLocation) {
      branchId = await _nearestBranchId(
        report.latitude,
        report.longitude,
      );
    }

    if (branchId == null) {
      throw StateError(
        'No se pudo relacionar este precio con un negocio de JOSEO.',
      );
    }

    final numericPrice = double.tryParse(
      report.price.replaceAll(',', '.').trim(),
    );

    if (numericPrice == null || numericPrice <= 0) {
      throw StateError('El precio no es válido.');
    }

    String? storagePath;

    if (report.photoPath != null) {
      final photoFile = File(report.photoPath!);

      if (await photoFile.exists()) {
        final extension = _extensionForPath(report.photoPath!);
        storagePath = '$userId/${report.id}$extension';

        try {
          await client.storage.from(_photoBucket).upload(
                storagePath,
                photoFile,
                fileOptions: FileOptions(
                  upsert: false,
                  contentType: _contentTypeForExtension(extension),
                ),
              );
        } catch (error) {
          // Si una subida anterior llegó a Storage pero falló la escritura
          // en la tabla, el reintento encuentra el mismo archivo. Eso no es
          // un error: continuamos usando la misma ruta.
          final message = error.toString().toLowerCase();
          final alreadyExists =
              message.contains('already exists') ||
              message.contains('duplicate') ||
              message.contains('409');

          if (!alreadyExists) {
            rethrow;
          }
        }
      }
    }

    final payload = <String, dynamic>{
      'client_report_id': report.id,
      'product_id': productId,
      'branch_id': branchId,
      'user_id': userId,
      'price': numericPrice,
      'regular_price': null,
      'is_offer': report.isOffer,
      'observed_at':
          (report.locationCapturedAt ?? report.createdAt).toIso8601String(),
      'expires_at': null,
      'photo_url': storagePath,
      'status': 'active',
      'created_at': report.createdAt.toIso8601String(),
      'description': report.description.isEmpty
          ? null
          : report.description,
      'captured_latitude': report.latitude,
      'captured_longitude': report.longitude,
      'captured_accuracy': report.accuracy,
      'location_captured_at':
          report.locationCapturedAt?.toIso8601String(),
      'location_source':
          report.useGpsLocation ? 'gps' : 'manual',
    };

    await client.from('prices').upsert(
          payload,
          onConflict: 'client_report_id',
        );
  }

  Future<int?> _nearestBranchId(
    double? latitude,
    double? longitude,
  ) async {
    if (latitude == null || longitude == null) {
      return null;
    }

    final rows = await Supabase.instance.client
        .from('branches')
        .select('id, name, latitude, longitude, active')
        .eq('active', true);

    int? nearestId;
    var nearestDistance = double.infinity;

    for (final row in rows) {
      final branchLatitude =
          (row['latitude'] as num?)?.toDouble();
      final branchLongitude =
          (row['longitude'] as num?)?.toDouble();

      if (branchLatitude == null || branchLongitude == null) {
        continue;
      }

      final distance = Geolocator.distanceBetween(
        latitude,
        longitude,
        branchLatitude,
        branchLongitude,
      );

      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestId = row['id'] as int?;
      }
    }

    // Evita asignar por error una sucursal muy lejana.
    if (nearestDistance > 1500) {
      return null;
    }

    return nearestId;
  }

  int? _legacyProductIdFromName(String name) {
    final value = name.toLowerCase();

    if (value.contains('aceite crisol')) return 1;
    if (value.contains('leche rica')) return 2;
    if (value.contains('arroz selecto')) return 3;
    if (value.contains('sazón') || value.contains('sazon')) return 4;
    if (value.contains('maggi')) return 5;
    if (value.contains('scott')) return 6;
    if (value.contains('clorox')) return 7;
    if (value.contains('colgate')) return 8;

    return null;
  }

  int? _legacyBranchIdFromName(String? name) {
    if (name == null) return null;

    final value = name.toLowerCase();

    if (value.contains('nacional')) return 1;
    if (value.contains('jumbo')) return 2;
    if (value.contains('bravo')) return 3;
    if (value.contains('olé') || value.contains('ole')) return 4;
    if (value.contains('iberia')) return 5;
    if (value.contains('estados unidos')) return 6;
    if (value.contains('a precio')) return 7;
    if (value.contains('hoyo de friusa')) return 8;

    return null;
  }

  String _extensionForPath(String path) {
    final lower = path.toLowerCase();

    if (lower.endsWith('.png')) return '.png';
    if (lower.endsWith('.jpeg')) return '.jpeg';
    if (lower.endsWith('.webp')) return '.webp';
    return '.jpg';
  }

  String _contentTypeForExtension(String extension) {
    switch (extension) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.jpeg':
        return 'image/jpeg';
      default:
        return 'image/jpeg';
    }
  }

  Future<void> _deleteLocalPhoto(String? path) async {
    if (path == null) return;

    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error) {
      debugPrint('JOSEO: no se pudo limpiar la foto local: $error');
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://hanyalgatnavbbxcxltu.supabase.co',
   publishableKey: 'sb_publishable_7xbymMEG0_RXgi6WUIsndw_OSnXOVhn',
  );

  await JoseoSyncManager.instance.start();

  runApp(const JoseoApp());
}

// ============================================================
// COLORES JOSEO
// ============================================================

const joseoBg = Color(0xFF05031D);
const joseoBg2 = Color(0xFF0C072B);
const joseoCard = Color(0xFF13102F);
const joseoCard2 = Color(0xFF1C1243);

const joseoPurple = Color(0xFF6420CF);
const joseoPurple2 = Color(0xFF8D2BF0);

const joseoGreen = Color(0xFF86E019);
const joseoDarkGreen = Color(0xFF048C3B);

const joseoGold = Color(0xFFFFC928);
const joseoOrange = Color(0xFFFF8A00);
const joseoRed = Color(0xFFFF4B4B);

// ============================================================
// MONETIZACIÓN, GAMIFICACIÓN Y DATOS COMUNITARIOS JOSEO
// ============================================================

class SponsoredOfferPreview {
  final String sponsor;
  final String title;
  final String subtitle;
  final String price;
  final String oldPrice;
  final String tag;
  final IconData icon;

  const SponsoredOfferPreview({
    required this.sponsor,
    required this.title,
    required this.subtitle,
    required this.price,
    required this.oldPrice,
    required this.tag,
    required this.icon,
  });
}

class JoseoLevelDefinition {
  final String name;
  final int minXp;
  final int maxXp;
  final String asset;

  const JoseoLevelDefinition({
    required this.name,
    required this.minXp,
    required this.maxXp,
    required this.asset,
  });
}

class JoseoAchievementDefinition {
  final String title;
  final String description;
  final int rewardXp;
  final String asset;

  const JoseoAchievementDefinition({
    required this.title,
    required this.description,
    required this.rewardXp,
    required this.asset,
  });
}

class JoseoGamification {
  // En la siguiente etapa estos valores vendrán de Supabase.
  // Por ahora comienzan en cero para no mostrar progreso ficticio.
  static const int previewXp = 0;
  static const int previewPublishedPrices = 0;
  static const int previewConfirmedPrices = 0;

  static const levels = <JoseoLevelDefinition>[
    JoseoLevelDefinition(
      name: 'Joseador Novato',
      minXp: 0,
      maxXp: 499,
      asset: JoseoAssets.moneda1,
    ),
    JoseoLevelDefinition(
      name: 'Joseador Activo',
      minXp: 500,
      maxXp: 1499,
      asset: JoseoAssets.copita,
    ),
    JoseoLevelDefinition(
      name: 'Cazador de Ofertas',
      minXp: 1500,
      maxXp: 3499,
      asset: JoseoAssets.escudo,
    ),
    JoseoLevelDefinition(
      name: 'Experto del Ahorro',
      minXp: 3500,
      maxXp: 6999,
      asset: JoseoAssets.ganaPuntos,
    ),
    JoseoLevelDefinition(
      name: 'Leyenda JOSEO',
      minXp: 7000,
      maxXp: 999999,
      asset: JoseoAssets.corona,
    ),
  ];

  static const achievements = <JoseoAchievementDefinition>[
    JoseoAchievementDefinition(
      title: 'Primer Joseo',
      description: 'Publica tu primer precio verificado.',
      rewardXp: 50,
      asset: JoseoAssets.moneda1,
    ),
    JoseoAchievementDefinition(
      title: 'Publicador frecuente',
      description: 'Publica 10 precios que la comunidad pueda validar.',
      rewardXp: 250,
      asset: JoseoAssets.corona,
    ),
    JoseoAchievementDefinition(
      title: 'Cazador verificado',
      description: 'Consigue 25 confirmaciones de otros usuarios.',
      rewardXp: 400,
      asset: JoseoAssets.escudo,
    ),
    JoseoAchievementDefinition(
      title: 'Explorador de tiendas',
      description: 'Reporta precios válidos en 5 sucursales diferentes.',
      rewardXp: 300,
      asset: JoseoAssets.ganaPuntos,
    ),
    JoseoAchievementDefinition(
      title: 'Corazón de la comunidad',
      description: 'Ayuda de forma constante con aportes confiables.',
      rewardXp: 700,
      asset: JoseoAssets.corazon,
    ),
  ];

  static JoseoLevelDefinition levelForXp(int xp) {
    for (final level in levels.reversed) {
      if (xp >= level.minXp) return level;
    }
    return levels.first;
  }

  static double progressForXp(int xp) {
    final level = levelForXp(xp);
    if (level.maxXp >= 999999) return 1.0;

    final span = level.maxXp - level.minXp + 1;
    final progress = (xp - level.minXp) / span;
    return progress.clamp(0.0, 1.0).toDouble();
  }
}

const sponsoredPreviewOffers = <SponsoredOfferPreview>[
  SponsoredOfferPreview(
    sponsor: 'Espacio para supermercado',
    title: 'Oferta patrocinada destacada',
    subtitle: 'Campaña administrada desde JOSEO',
    price: 'RD\$ --',
    oldPrice: 'RD\$ --',
    tag: 'PATROCINADO',
    icon: Icons.storefront_rounded,
  ),
  SponsoredOfferPreview(
    sponsor: 'Espacio para marca',
    title: 'Producto promocionado',
    subtitle: 'Segmentable por zona y categoría',
    price: 'RD\$ --',
    oldPrice: 'RD\$ --',
    tag: 'PATROCINADO',
    icon: Icons.campaign_rounded,
  ),
];

// ============================================================
// IMÁGENES
// ============================================================

class JoseoAssets {
  static const base = 'lib/assets/images/';

  static const ayudaAhorrar = '${base}ayuda ahorrar.png';
  static const buscarProducto = '${base}buscar producto.png';
  static const recibeAlertas = '${base}Campana recibe alertas.png';
  static const campanita = '${base}campanita ade notificaciones.png';
  static const carrito = '${base}carrito de compras.png';

  static const cintillo1 = '${base}Cintillo 1.png';
  static const cintillo2 = '${base}Cintillo 2.png';
  static const cintillo3 = '${base}Cintillo 3.png';

  static const ganaPuntos = '${base}copa gana puntos.png';
  static const copita = '${base}copita.png';
  static const corazon = '${base}Corazon.png';
  static const corona = '${base}corona.png';
  static const coronita2 = '${base}Coronita 2.png';
  static const escudo = '${base}Escudo con estrella.png';

  static const compararPrecios =
      '${base}Etiqueta comparar precios.png';

  static const grafico = '${base}grafico.png';

  static const joseSaltando = '${base}Jose Saltando.png';
  static const joseLupa = '${base}Josecon lupa.png';
  static const joseParado = '${base}Joseo parado 1.png';
  static const joseo = '${base}joseo.png';

  static const llamita2 = '${base}llamita 2.png';
  static const llamita = '${base}Llamita.png';

  static const logoCirculo = '${base}logo circulo joseo.png';
  static const logoCuadrado = '${base}logo cuadrado joseo.png';

  static const joseCarrito =
      '${base}Logo Joseo carrito de compras.png';

  static const logoPortada2 = '${base}Logo portada Joseo 2.png';
  static const logoPortada3 = '${base}Logo portada Joseo 3.png';
  static const logoPortada = '${base}Logo portada Joseo.png';

  static const mapaLista = '${base}MApa-Lista.png';

  static const moneda1 = '${base}moneda 1.png';
  static const moneda2 = '${base}moneda 2.png';
  static const moneda3 = '${base}moneda 3.png';

  static const pinLocalizacion =
      '${base}Pint de localizacion.png';

  static const puntero1 = '${base}Puntero 1.png';
  static const puntero2 = '${base}Puntero 2.png';
}

// ============================================================
// IMAGEN SEGURA
// ============================================================

class SafeAsset extends StatelessWidget {
  final String asset;
  final double? width;
  final double? height;
  final BoxFit fit;
  final IconData fallback;

  const SafeAsset({
    super.key,
    required this.asset,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.fallback = Icons.image_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stackTrace) {
        return SizedBox(
          width: width,
          height: height,
          child: Icon(
            fallback,
            color: joseoGreen,
            size: height == null ? 30 : height! * .55,
          ),
        );
      },
    );
  }
}


enum JoseoLegalDocument {
  privacy,
  terms,
  community,
}

class JoseoLegalDocumentPage extends StatelessWidget {
  final JoseoLegalDocument document;

  const JoseoLegalDocumentPage({
    super.key,
    required this.document,
  });

  String get _title {
    switch (document) {
      case JoseoLegalDocument.privacy:
        return 'Política de Privacidad';
      case JoseoLegalDocument.terms:
        return 'Términos de Uso';
      case JoseoLegalDocument.community:
        return 'Normas de la Comunidad';
    }
  }

  List<({String heading, String body})> get _sections {
    switch (document) {
      case JoseoLegalDocument.privacy:
        return const [
          (
            heading: 'Última actualización',
            body: '27 de agosto de 2026',
          ),
          (
            heading: 'Responsable y contacto',
            body:
                'JOSEO es una aplicación comunitaria orientada a ayudar a los usuarios a identificar, comparar y compartir precios de productos y comercios en la República Dominicana.\n\n'
                'Responsable: Anibal Santana\n'
                'Correo de contacto y privacidad: Anibal.santanac@gmail.com',
          ),
          (
            heading: '1. Información que podemos recopilar',
            body:
                'JOSEO puede tratar los datos necesarios para operar el servicio, incluyendo nombre, correo electrónico, identificador interno de usuario y datos de autenticación.\n\n'
                'También puede tratar la información que el usuario decida publicar, como precios, productos, descripciones, comercios, sucursales, fotografías, validaciones y reportes.\n\n'
                'Cuando el usuario lo autorice, JOSEO podrá acceder a la ubicación del dispositivo para identificar o respaldar el lugar donde se observó un precio, localizar establecimientos cercanos o registrar una publicación. La ubicación no se utilizará para publicidad personalizada.\n\n'
                'Cuando el usuario decida adjuntar evidencia, JOSEO podrá acceder a la cámara o galería para seleccionar o capturar fotografías relacionadas con un precio o publicación.',
          ),
          (
            heading: '2. Para qué utilizamos la información',
            body:
                'La información se utiliza para crear y administrar cuentas, permitir publicaciones, asociar precios con establecimientos, mostrar comparaciones, validar aportes comunitarios, operar puntos y niveles, prevenir fraude o abuso, moderar contenido, atender soporte y mejorar la seguridad y funcionamiento de JOSEO.',
          ),
          (
            heading: '3. Radar JOSEO y datos comunitarios',
            body:
                'El Radar JOSEO utiliza información reciente aportada por la comunidad y aplica reglas de confianza para realizar comparaciones entre establecimientos.\n\n'
                'JOSEO puede excluir precios, establecimientos o publicaciones que no cumplan criterios mínimos de actualidad, consistencia, verificación o confiabilidad.\n\n'
                'El Radar es una herramienta informativa y no garantiza que un establecimiento mantenga un precio determinado al momento de la compra.',
          ),
          (
            heading: '4. Contenido público',
            body:
                'Algunas contribuciones realizadas por los usuarios podrán ser visibles para otros miembros de la comunidad, incluyendo precios, productos, comercios, fotografías, fechas aproximadas de publicación y estado de validación.\n\n'
                'JOSEO procurará no mostrar públicamente información privada innecesaria del usuario.',
          ),
          (
            heading: '5. Fotografías y evidencia',
            body:
                'El usuario debe evitar subir fotografías que contengan documentos de identidad, tarjetas bancarias, datos médicos, números de cuenta, información confidencial o información privada de terceros.\n\n'
                'JOSEO podrá retirar fotografías que incumplan estas reglas o que no sean necesarias para respaldar la publicación.',
          ),
          (
            heading: '6. Proveedores tecnológicos',
            body:
                'JOSEO puede utilizar proveedores tecnológicos para autenticación, base de datos, almacenamiento, infraestructura y seguridad. Actualmente, parte de la infraestructura tecnológica utiliza Supabase.\n\n'
                'Estos proveedores pueden procesar la información técnicamente necesaria para prestar sus servicios.',
          ),
          (
            heading: '7. Publicidad y ofertas patrocinadas',
            body:
                'JOSEO puede mostrar promociones u ofertas pagadas por comercios o anunciantes. Dicho contenido deberá identificarse claramente como “Patrocinado”, “Publicidad” o expresión equivalente.\n\n'
                'Las ofertas patrocinadas son distintas de los precios aportados por la comunidad y no deben influir directamente en los resultados del Radar JOSEO.',
          ),
          (
            heading: '8. Seguridad',
            body:
                'JOSEO adopta medidas técnicas y organizativas razonables destinadas a proteger la información contra acceso no autorizado, pérdida, alteración, divulgación o uso indebido. Ningún sistema conectado a Internet puede garantizar seguridad absoluta.',
          ),
          (
            heading: '9. Conservación de datos',
            body:
                'Los datos podrán conservarse mientras la cuenta permanezca activa o mientras sean necesarios para prestar el servicio, prevenir fraude, resolver disputas o cumplir obligaciones legales.\n\n'
                'Cuando el usuario solicite la eliminación de su cuenta, JOSEO eliminará o anonimizará los datos personales cuando corresponda, salvo información que deba conservarse por una razón legal, de seguridad o prevención de fraude.',
          ),
          (
            heading: '10. Derechos del usuario',
            body:
                'El usuario podrá solicitar, según corresponda, acceso, corrección, actualización o eliminación de sus datos personales, así como información sobre su tratamiento.\n\n'
                'Las solicitudes podrán enviarse a Anibal.santanac@gmail.com.',
          ),
          (
            heading: '11. Eliminación de cuenta',
            body:
                'JOSEO permitirá solicitar la eliminación de una cuenta desde la aplicación. También se habilitará un mecanismo externo para solicitar la eliminación de la cuenta y de los datos personales asociados.\n\n'
                'JOSEO podrá solicitar información razonable para verificar la identidad del solicitante antes de ejecutar la eliminación.',
          ),
          (
            heading: '12. Menores de edad',
            body:
                'JOSEO no está diseñada específicamente para recopilar datos personales de niños. Cuando corresponda, los menores deberán utilizar el servicio conforme a la legislación aplicable y bajo la autorización o supervisión de sus padres o tutores.',
          ),
          (
            heading: '13. Cambios y legislación aplicable',
            body:
                'Esta Política podrá actualizarse cuando cambien las funciones de JOSEO, sus proveedores tecnológicos o las obligaciones legales aplicables.\n\n'
                'Se interpretará conforme a las leyes aplicables de la República Dominicana, incluyendo las normas relativas a protección de datos personales y derechos de los consumidores.',
          ),
        ];
      case JoseoLegalDocument.terms:
        return const [
          (
            heading: 'Última actualización',
            body: '27 de agosto de 2026',
          ),
          (
            heading: '1. Naturaleza del servicio',
            body:
                'JOSEO es una plataforma tecnológica colaborativa destinada a facilitar la consulta y el intercambio de información sobre precios, productos, promociones y establecimientos.\n\n'
                'JOSEO no vende necesariamente los productos cuyos precios aparecen en la aplicación y no controla los precios, inventarios ni políticas comerciales de los establecimientos.',
          ),
          (
            heading: '2. Información de precios',
            body:
                'Los precios pueden provenir de usuarios, comercios o administradores y pueden cambiar en cualquier momento.\n\n'
                'La información mostrada debe entenderse como referencia. Antes de realizar una compra, el usuario debe confirmar directamente con el establecimiento el precio final, disponibilidad, impuestos, condiciones y vigencia.',
          ),
          (
            heading: '3. Cuenta del usuario',
            body:
                'El usuario es responsable de proporcionar información razonablemente correcta, proteger su contraseña y evitar el uso abusivo de su cuenta.\n\n'
                'JOSEO podrá limitar o suspender cuentas utilizadas para fraude, spam, manipulación de precios, acoso o incumplimiento de estos Términos.',
          ),
          (
            heading: '4. Publicaciones',
            body:
                'Al publicar información, el usuario declara que tiene razones razonables para creer que es correcta y que tiene derecho a compartir el contenido aportado.\n\n'
                'El usuario conserva los derechos que legalmente le correspondan sobre su contenido y concede a JOSEO una autorización no exclusiva para almacenarlo, procesarlo, mostrarlo y utilizarlo técnicamente dentro de la plataforma para prestar el servicio.',
          ),
          (
            heading: '5. Contenido prohibido',
            body:
                'No está permitido publicar deliberadamente precios falsos, negocios inexistentes, información engañosa, spam, amenazas, contenido ilegal, material sexual explícito, contenido discriminatorio, información privada de terceros, fotografías ajenas sin autorización o contenido destinado a manipular la reputación de personas o establecimientos.',
          ),
          (
            heading: '6. Validaciones comunitarias',
            body:
                'Los usuarios podrán indicar que un precio parece correcto o incorrecto. Estas validaciones deben realizarse de buena fe y no constituyen una certificación absoluta.\n\n'
                'Está prohibido usar varias cuentas o coordinar usuarios para manipular validaciones, reputaciones, precios, rankings o indicadores de JOSEO.',
          ),
          (
            heading: '7. Sistema de puntos',
            body:
                'JOSEO puede ofrecer puntos, XP, niveles, insignias o reconocimientos con fines de participación y gamificación. Salvo que se indique expresamente lo contrario, estos elementos no representan dinero, saldo financiero ni derecho a recibir efectivo.\n\n'
                'JOSEO podrá corregir o eliminar puntos obtenidos mediante fraude, manipulación o abuso.',
          ),
          (
            heading: '8. Publicidad',
            body:
                'JOSEO puede mostrar anuncios y publicaciones patrocinadas. La contratación de publicidad no garantiza una posición favorable en comparaciones comunitarias, validaciones o resultados del Radar JOSEO.',
          ),
          (
            heading: '9. Moderación',
            body:
                'JOSEO podrá revisar, ocultar, rechazar o eliminar contenido cuando existan razones razonables para considerar que es falso, ilegal, abusivo, inseguro, spam o contrario a estas reglas.\n\n'
                'JOSEO podrá aplicar medidas proporcionales, incluyendo advertencias, eliminación de contenido, suspensión temporal o cierre de cuenta.',
          ),
          (
            heading: '10. Limitación razonable de responsabilidad',
            body:
                'JOSEO procura ofrecer información útil y confiable, pero depende en parte de datos aportados por terceros. Por ello no garantiza que todos los precios permanezcan vigentes, que todos los productos estén disponibles o que todas las publicaciones sean correctas.\n\n'
                'Nada de estos Términos pretende excluir derechos que la legislación aplicable reconozca obligatoriamente a los consumidores.',
          ),
          (
            heading: '11. Legislación y contacto',
            body:
                'Estos Términos se regirán por las leyes de la República Dominicana, sin perjuicio de los derechos irrenunciables que correspondan al usuario.\n\n'
                'Contacto: Anibal Santana — Anibal.santanac@gmail.com',
          ),
        ];
      case JoseoLegalDocument.community:
        return const [
          (
            heading: 'La regla principal',
            body:
                'JOSEO funciona porque las personas comparten información útil. Publica lo que realmente viste.',
          ),
          (
            heading: 'Información verdadera',
            body:
                'No inventes precios, promociones, comercios o sucursales. No alteres información para favorecer o perjudicar a un establecimiento.',
          ),
          (
            heading: 'Validaciones de buena fe',
            body:
                'No utilices la opción “Incorrecto” simplemente porque no te guste otro usuario o establecimiento. Debe utilizarse cuando existan razones reales para creer que la información es equivocada.\n\n'
                'Recuerda que un establecimiento puede cambiar un precio después de una publicación. Eso no significa necesariamente que el usuario haya mentido.',
          ),
          (
            heading: 'No manipules la comunidad',
            body:
                'No utilices varias cuentas para confirmar tus propias publicaciones, generar XP artificialmente, atacar a otros usuarios o alterar los resultados del Radar JOSEO.',
          ),
          (
            heading: 'Respeto y seguridad',
            body:
                'No se permiten amenazas, acoso, discriminación, contenido ilegal, material sexual explícito, spam ni publicaciones diseñadas para perjudicar deliberadamente a otra persona.',
          ),
          (
            heading: 'Protege la privacidad',
            body:
                'Evita publicar rostros, documentos personales, números de teléfono, tarjetas, datos financieros u otra información privada que no sea necesaria para reportar un precio.',
          ),
          (
            heading: 'Fotografías',
            body:
                'Las fotografías deben estar relacionadas con el precio, producto, promoción o establecimiento reportado y deben respetar la privacidad y derechos de terceros.',
          ),
          (
            heading: 'Reportes y moderación',
            body:
                'Los usuarios podrán reportar contenido que consideren falso, peligroso, ofensivo, fraudulento o contrario a estas normas.\n\n'
                'JOSEO podrá investigar los reportes y aplicar medidas como advertencia, eliminación del contenido, suspensión temporal o cierre de cuenta, según la gravedad y reincidencia.',
          ),
          (
            heading: 'Contacto',
            body:
                'Para consultas relacionadas con estas normas puedes escribir a Anibal.santanac@gmail.com.',
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: joseoBg,
      appBar: AppBar(
        backgroundColor: joseoBg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          _title,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D062A), joseoBg],
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: joseoCard,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: joseoPurple.withValues(alpha: .25),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.gavel_outlined, color: joseoGold),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'JOSEO • República Dominicana',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .85),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ..._sections.map(
              (section) => Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: joseoCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section.heading,
                      style: const TextStyle(
                        color: joseoGreen,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      section.body,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


const String _joseoRecoveryRequestedAtKey = 'joseo_password_recovery_requested_at';

Future<void> _markJoseoPasswordRecoveryRequested() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(
    _joseoRecoveryRequestedAtKey,
    DateTime.now().millisecondsSinceEpoch,
  );
}

Future<void> _clearJoseoPasswordRecoveryRequested() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_joseoRecoveryRequestedAtKey);
}

Future<bool> _hasFreshJoseoPasswordRecoveryRequest() async {
  final prefs = await SharedPreferences.getInstance();
  final value = prefs.getInt(_joseoRecoveryRequestedAtKey);
  if (value == null) return false;

  final requestedAt = DateTime.fromMillisecondsSinceEpoch(value);
  final age = DateTime.now().difference(requestedAt);

  // La solicitud solo sirve como señal temporal para recuperar una cuenta.
  // Evitamos abrir la pantalla días después por una marca antigua.
  if (age.isNegative || age > const Duration(hours: 1)) {
    await prefs.remove(_joseoRecoveryRequestedAtKey);
    return false;
  }

  return true;
}

// ============================================================
// AUTENTICACIÓN JOSEO
// ============================================================

class JoseoAuthPage extends StatefulWidget {
  final bool startInRegisterMode;
  final String? initialEmail;

  const JoseoAuthPage({
    super.key,
    this.startInRegisterMode = false,
    this.initialEmail,
  });

  @override
  State<JoseoAuthPage> createState() => _JoseoAuthPageState();
}

class _JoseoAuthPageState extends State<JoseoAuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _registerMode = false;
  bool _loading = false;
  bool _hidePassword = true;
  bool _acceptedLegal = false;

  @override
  void initState() {
    super.initState();
    _registerMode = widget.startInRegisterMode;
    _emailController.text = widget.initialEmail?.trim() ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _friendlyAuthError(Object error) {
    final raw = error.toString().toLowerCase();

    if (raw.contains('invalid login credentials')) {
      return 'Correo o contraseña incorrectos.';
    }
    if (raw.contains('email not confirmed')) {
      return 'Primero confirma tu correo desde el mensaje que te envió JOSEO.';
    }
    if (raw.contains('user already registered')) {
      return 'Ya existe una cuenta con ese correo. Inicia sesión.';
    }
    if (raw.contains('password should be at least')) {
      return 'La contraseña debe tener al menos 6 caracteres.';
    }
    if (raw.contains('unable to validate email') ||
        raw.contains('invalid email')) {
      return 'Escribe un correo electrónico válido.';
    }
    if (raw.contains('rate limit') || raw.contains('too many')) {
      return 'Se han enviado demasiados intentos. Espera un momento y prueba otra vez.';
    }
    if (raw.contains('network') ||
        raw.contains('socket') ||
        raw.contains('connection')) {
      return 'No pudimos conectar con internet. Inténtalo nuevamente.';
    }

    return 'No pudimos completar la operación. Inténtalo nuevamente.';
  }

  Future<void> _sendPasswordRecovery() async {
    if (_loading) return;

    final email = _emailController.text.trim();

    if (email.isEmpty || !email.contains('@') || !email.contains('.')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Escribe primero el correo de tu cuenta JOSEO.'),
        ),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _loading = true);

    try {
      await _markJoseoPasswordRecoveryRequested();

      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'joseo://reset-password/',
      );

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: joseoCard,
            title: const Text('Revisa tu correo ✉️'),
            content: Text(
              'Si existe una cuenta JOSEO con $email, recibirás un enlace para crear una contraseña nueva. '
              'Abre el enlace desde este teléfono y JOSEO continuará automáticamente.',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text(
                  'Entendido',
                  style: TextStyle(color: joseoGreen),
                ),
              ),
            ],
          );
        },
      );
    } on AuthException catch (error) {
      await _clearJoseoPasswordRecoveryRequested();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyAuthError(error.message))),
      );
    } catch (error) {
      await _clearJoseoPasswordRecoveryRequested();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyAuthError(error))),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_registerMode && !_acceptedLegal) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Para crear tu cuenta debes aceptar los Términos de Uso, la Política de Privacidad y las Normas de la Comunidad.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _loading = true;
    });

    final auth = Supabase.instance.client.auth;
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      if (_registerMode) {
        final fullName = _nameController.text.trim();

        final response = await auth.signUp(
          email: email,
          password: password,
          data: {
            'full_name': fullName,
          },
        );

        if (!mounted) return;

        if (response.session != null) {
          await JoseoSyncManager.instance.checkPendingReports();
          if (!mounted) return;
          Navigator.pop(context, true);
          return;
        }

        await showDialog<void>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: joseoCard,
              title: const Text('Confirma tu correo ✉️'),
              content: Text(
                'Creamos tu cuenta. Enviamos un enlace de confirmación a $email. '
                'Ábrelo y luego vuelve a JOSEO para iniciar sesión.',
                style: const TextStyle(
                  color: Colors.white70,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text(
                    'Entendido',
                    style: TextStyle(color: joseoGreen),
                  ),
                ),
              ],
            );
          },
        );

        if (!mounted) return;

        setState(() {
          _registerMode = false;
          _passwordController.clear();
        });
      } else {
        await auth.signInWithPassword(
          email: email,
          password: password,
        );

        await JoseoSyncManager.instance.checkPendingReports();

        if (!mounted) return;
        Navigator.pop(context, true);
      }
    } on AuthException catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyAuthError(error.message)),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyAuthError(error)),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _switchMode() {
    if (_loading) return;

    setState(() {
      _registerMode = !_registerMode;
      _passwordController.clear();
      _acceptedLegal = false;
    });
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white60),
      prefixIcon: Icon(icon, color: joseoGreen),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: joseoCard,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: joseoPurple.withValues(alpha: .30),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(
          color: joseoGreen,
          width: 1.5,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: joseoRed),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(
          color: joseoRed,
          width: 1.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: joseoBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          onPressed: _loading ? null : () => Navigator.pop(context, false),
          icon: const Icon(Icons.arrow_back_ios_new),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.3,
              colors: [
                Color(0xFF23105D),
                Color(0xFF0B0328),
                joseoBg,
              ],
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 30),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  const SafeAsset(
                    asset: JoseoAssets.logoCirculo,
                    width: 110,
                    height: 110,
                    fallback: Icons.savings_outlined,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'JOSEO',
                    style: TextStyle(
                      color: joseoGreen,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _registerMode
                        ? 'Crea tu cuenta para publicar y ayudar a la comunidad.'
                        : 'Entra a tu cuenta para publicar precios y ganar puntos.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (_registerMode) ...[
                    TextFormField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: _inputDecoration(
                        label: 'Nombre',
                        icon: Icons.person_outline,
                      ),
                      validator: (value) {
                        if (!_registerMode) return null;
                        if (value == null || value.trim().length < 2) {
                          return 'Escribe tu nombre.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 13),
                  ],
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: _inputDecoration(
                      label: 'Correo electrónico',
                      icon: Icons.email_outlined,
                    ),
                    validator: (value) {
                      final email = value?.trim() ?? '';
                      if (email.isEmpty ||
                          !email.contains('@') ||
                          !email.contains('.')) {
                        return 'Escribe un correo válido.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 13),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _hidePassword,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: _inputDecoration(
                      label: 'Contraseña',
                      icon: Icons.lock_outline,
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() {
                            _hidePassword = !_hidePassword;
                          });
                        },
                        icon: Icon(
                          _hidePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.length < 6) {
                        return 'Mínimo 6 caracteres.';
                      }
                      return null;
                    },
                  ),
                  if (_registerMode) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      decoration: BoxDecoration(
                        color: joseoCard,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _acceptedLegal
                              ? joseoGreen.withValues(alpha: .55)
                              : Colors.white10,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: _acceptedLegal,
                            activeColor: joseoGreen,
                            checkColor: Colors.black,
                            onChanged: _loading
                                ? null
                                : (value) {
                                    setState(() {
                                      _acceptedLegal = value ?? false;
                                    });
                                  },
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  const Text(
                                    'He leído y acepto los ',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10.5,
                                      height: 1.35,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const JoseoLegalDocumentPage(
                                            document: JoseoLegalDocument.terms,
                                          ),
                                        ),
                                      );
                                    },
                                    child: const Text(
                                      'Términos de Uso',
                                      style: TextStyle(
                                        color: joseoGold,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w900,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                                  const Text(
                                    ', la ',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10.5,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const JoseoLegalDocumentPage(
                                            document: JoseoLegalDocument.privacy,
                                          ),
                                        ),
                                      );
                                    },
                                    child: const Text(
                                      'Política de Privacidad',
                                      style: TextStyle(
                                        color: joseoGold,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w900,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                                  const Text(
                                    ' y las ',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10.5,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const JoseoLegalDocumentPage(
                                            document: JoseoLegalDocument.community,
                                          ),
                                        ),
                                      );
                                    },
                                    child: const Text(
                                      'Normas de la Comunidad',
                                      style: TextStyle(
                                        color: joseoGold,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w900,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                                  const Text(
                                    ' de JOSEO.',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (!_registerMode) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _loading ? null : _sendPasswordRecovery,
                        child: const Text(
                          '¿Olvidaste tu contraseña?',
                          style: TextStyle(
                            color: joseoGold,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: joseoGreen,
                        foregroundColor: Colors.black,
                        disabledBackgroundColor:
                            joseoGreen.withValues(alpha: .45),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.black,
                              ),
                            )
                          : Text(
                              _registerMode
                                  ? 'Crear mi cuenta'
                                  : 'Iniciar sesión',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _loading ? null : _switchMode,
                    child: Text(
                      _registerMode
                          ? '¿Ya tienes cuenta? Inicia sesión'
                          : '¿No tienes cuenta? Regístrate',
                      style: const TextStyle(
                        color: joseoGold,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Puedes consultar precios sin registrarte. La cuenta es necesaria para publicar y participar en la comunidad.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class JoseoPasswordRecoveryPage extends StatefulWidget {
  const JoseoPasswordRecoveryPage({super.key});

  @override
  State<JoseoPasswordRecoveryPage> createState() =>
      _JoseoPasswordRecoveryPageState();
}

class _JoseoPasswordRecoveryPageState
    extends State<JoseoPasswordRecoveryPage> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _loading = false;
  bool _hidePassword = true;
  bool _hideConfirm = true;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _savePassword() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);

    final auth = Supabase.instance.client.auth;
    final email = auth.currentUser?.email;

    try {
      await auth.updateUser(
        UserAttributes(password: _passwordController.text),
      );

      await _clearJoseoPasswordRecoveryRequested();

      // Cerramos la sesión de recuperación. El usuario entra de nuevo
      // con su contraseña recién creada y evitamos dejar una sesión
      // especial abierta en un teléfono compartido.
      await auth.signOut();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Contraseña actualizada correctamente.'),
        ),
      );

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => JoseoAuthPage(initialEmail: email),
        ),
      );
    } on AuthException catch (error) {
      if (!mounted) return;
      final raw = error.message.toLowerCase();
      final message = raw.contains('password should be at least')
          ? 'La contraseña debe tener al menos 6 caracteres.'
          : 'No pudimos actualizar la contraseña. Solicita un enlace nuevo.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No pudimos actualizar la contraseña. Solicita un enlace nuevo.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  InputDecoration _decoration({
    required String label,
    required bool hidden,
    required VoidCallback onToggle,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white60),
      prefixIcon: const Icon(Icons.lock_outline, color: joseoGreen),
      suffixIcon: IconButton(
        onPressed: onToggle,
        icon: Icon(
          hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          color: Colors.white54,
        ),
      ),
      filled: true,
      fillColor: joseoCard,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: joseoPurple.withValues(alpha: .30)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: joseoGreen, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: joseoRed),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: joseoRed, width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: joseoBg,
        body: SafeArea(
          child: Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 1.3,
                colors: [
                  Color(0xFF23105D),
                  Color(0xFF0B0328),
                  joseoBg,
                ],
              ),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 36, 22, 30),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    const SafeAsset(
                      asset: JoseoAssets.logoCirculo,
                      width: 115,
                      height: 115,
                      fallback: Icons.lock_reset,
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Crea tu nueva contraseña',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'El enlace de recuperación fue validado. Escribe una contraseña nueva para tu cuenta JOSEO.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 30),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _hidePassword,
                      textInputAction: TextInputAction.next,
                      decoration: _decoration(
                        label: 'Nueva contraseña',
                        hidden: _hidePassword,
                        onToggle: () {
                          setState(() => _hidePassword = !_hidePassword);
                        },
                      ),
                      validator: (value) {
                        if (value == null || value.length < 6) {
                          return 'Mínimo 6 caracteres.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _confirmController,
                      obscureText: _hideConfirm,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _savePassword(),
                      decoration: _decoration(
                        label: 'Confirmar contraseña',
                        hidden: _hideConfirm,
                        onToggle: () {
                          setState(() => _hideConfirm = !_hideConfirm);
                        },
                      ),
                      validator: (value) {
                        if (value != _passwordController.text) {
                          return 'Las contraseñas no coinciden.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _savePassword,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: joseoGreen,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: Colors.black,
                                ),
                              )
                            : const Icon(Icons.lock_reset),
                        label: const Text(
                          'Guardar nueva contraseña',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Por seguridad, después de cambiarla JOSEO te pedirá iniciar sesión nuevamente.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// APP
// ============================================================

final GlobalKey<NavigatorState> joseoNavigatorKey =
    GlobalKey<NavigatorState>();

class JoseoApp extends StatefulWidget {
  const JoseoApp({super.key});

  @override
  State<JoseoApp> createState() => _JoseoAppState();
}

class _JoseoAppState extends State<JoseoApp> {
  StreamSubscription<AuthState>? _authSubscription;
  bool _recoveryPageOpen = false;

  @override
  void initState() {
    super.initState();

    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.passwordRecovery) {
        _openRecoveryPage();
      }
    });

    // En un arranque en frío Supabase puede consumir el deep link antes de
    // que este widget llegue a escuchar passwordRecovery. Por eso hacemos
    // una segunda comprobación persistente: si el usuario pidió recuperar
    // contraseña recientemente y el deep link ya creó una sesión temporal,
    // abrimos igualmente la pantalla de nueva contraseña.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingRecoverySession();
    });
  }

  Future<void> _checkPendingRecoverySession() async {
    if (_recoveryPageOpen) return;

    final pending = await _hasFreshJoseoPasswordRecoveryRequest();
    final hasSession = Supabase.instance.client.auth.currentSession != null;

    if (pending && hasSession) {
      _openRecoveryPage();
    }
  }

  void _openRecoveryPage() {
    if (_recoveryPageOpen) return;
    _recoveryPageOpen = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final navigator = joseoNavigatorKey.currentState;
      if (navigator == null) {
        _recoveryPageOpen = false;
        return;
      }

      await navigator.push(
        MaterialPageRoute(
          builder: (_) => const JoseoPasswordRecoveryPage(),
        ),
      );

      _recoveryPageOpen = false;
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: joseoNavigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'JOSEO',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: joseoBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: joseoGreen,
          brightness: Brightness.dark,
        ),
      ),
      home: const JoseoShell(),
    );
  }
}

// ============================================================
// SHELL
// ============================================================

class JoseoShell extends StatefulWidget {
  const JoseoShell({super.key});

  @override
  State<JoseoShell> createState() => _JoseoShellState();
}

class _JoseoShellState extends State<JoseoShell> with WidgetsBindingObserver {
  static const String _radiusPreferenceKey = 'joseo_search_radius_km';

  int currentIndex = 0;
  double _radiusKm = 20;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedRadius();
  }

  Future<void> _loadSavedRadius() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getDouble(_radiusPreferenceKey);
    if (!mounted || (saved != 10 && saved != 20)) return;
    setState(() => _radiusKm = saved!);
  }

  Future<void> _changeRadius(double radiusKm) async {
    if (radiusKm != 10 && radiusKm != 20) return;
    if (_radiusKm == radiusKm) return;

    setState(() => _radiusKm = radiusKm);

    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(_radiusPreferenceKey, radiusKm);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      JoseoSyncManager.instance.checkPendingReports();
      if (mounted) setState(() {});
    }
  }

  Future<bool> _ensureAuthenticated() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      return true;
    }

    final authenticated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const JoseoAuthPage(),
      ),
    );

    if (!mounted) return false;

    setState(() {});

    return authenticated == true &&
        Supabase.instance.client.auth.currentUser != null;
  }

  Future<void> changePage(int index) async {
    if (index == 2) {
      final canPublish = await _ensureAuthenticated();
      if (!canPublish || !mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const AddPricePage(),
        ),
      );

      if (mounted) {
        setState(() {});
      }
      return;
    }

    setState(() {
      currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(
        goMap: () => changePage(1),
        goOffers: () => changePage(3),
        radiusKm: _radiusKm,
        onRadiusChanged: _changeRadius,
      ),
      MapPage(
        radiusKm: _radiusKm,
        onRadiusChanged: _changeRadius,
      ),
      const SizedBox(),
      OffersPage(
        radiusKm: _radiusKm,
        onRadiusChanged: _changeRadius,
      ),
      const ProfilePage(),
    ];

    return Scaffold(
      body: IndexedStack(
        index: currentIndex,
        children: pages,
      ),
      bottomNavigationBar: JoseoBottomBar(
        currentIndex: currentIndex,
        onTap: (index) {
          changePage(index);
        },
      ),
    );
  }
}

// ============================================================
// BOTTOM BAR
// ============================================================

class JoseoBottomBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const JoseoBottomBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 82,
      decoration: BoxDecoration(
        color: const Color(0xFF09021E),
        border: Border(
          top: BorderSide(
            color: joseoPurple.withValues(alpha: .25),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            nav(0, Icons.home_rounded, 'Inicio'),
            nav(1, Icons.map_outlined, 'Mapa'),

            GestureDetector(
              onTap: () => onTap(2),
              child: Transform.translate(
                offset: const Offset(0, -13),
                child: Container(
                  width: 65,
                  height: 65,
                  decoration: BoxDecoration(
                    color: joseoGreen,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF27104E),
                      width: 6,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: joseoGreen.withValues(alpha: .35),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.add,
                    color: Colors.black,
                    size: 38,
                  ),
                ),
              ),
            ),

            nav(3, Icons.sell_outlined, 'Ofertas'),
            nav(4, Icons.person_outline, 'Perfil'),
          ],
        ),
      ),
    );
  }

  Widget nav(int index, IconData icon, String label) {
    final selected = currentIndex == index;

    return InkWell(
      onTap: () => onTap(index),
      child: SizedBox(
        width: 62,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color:
                  selected ? joseoGreen : Colors.white54,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color:
                    selected ? joseoGreen : Colors.white54,
                fontWeight: selected
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// RADAR JOSEO - MODELO DE LECTURA
// ============================================================

class JoseoRadarStore {
  final int storeId;
  final int branchId;
  final String supermarket;
  final String branchName;
  final double distanceKm;
  final int comparableProductCount;
  final int webProductCount;
  final int communityProductCount;
  final double savingsPercent;
  final int contributionCount;
  final int confirmationCount;
  final DateTime? updatedAt;
  final String confidence;
  final bool publishable;

  const JoseoRadarStore({
    required this.storeId,
    required this.branchId,
    required this.supermarket,
    required this.branchName,
    required this.distanceKm,
    required this.comparableProductCount,
    required this.webProductCount,
    required this.communityProductCount,
    required this.savingsPercent,
    required this.contributionCount,
    required this.confirmationCount,
    required this.updatedAt,
    required this.confidence,
    required this.publishable,
  });

  factory JoseoRadarStore.fromMap(Map<String, dynamic> row) {
    return JoseoRadarStore(
      storeId: (row['store_id'] as num).toInt(),
      branchId: (row['branch_id'] as num?)?.toInt() ?? 0,
      supermarket: row['supermercado'] as String? ?? 'Supermercado',
      branchName: row['sucursal'] as String? ?? '',
      distanceKm: (row['distance_km'] as num?)?.toDouble() ?? 0,
      comparableProductCount:
          (row['comparable_product_count'] as num?)?.toInt() ?? 0,
      webProductCount:
          (row['web_product_count'] as num?)?.toInt() ?? 0,
      communityProductCount:
          (row['community_product_count'] as num?)?.toInt() ?? 0,
      savingsPercent:
          (row['ahorro_porcentaje'] as num?)?.toDouble() ?? 0,
      contributionCount:
          (row['contribution_count'] as num?)?.toInt() ?? 0,
      confirmationCount:
          (row['confirmation_count'] as num?)?.toInt() ?? 0,
      updatedAt: row['updated_at'] == null
          ? null
          : DateTime.tryParse(row['updated_at'].toString()),
      confidence: row['confianza'] as String? ?? 'baja',
      publishable: row['publicable'] == true,
    );
  }
}

// ============================================================
// DATOS REALES JOSEO - PRECIOS, XP, PUBLICIDAD Y ADMIN
// ============================================================

class JoseoSponsoredOffer {
  final int id;
  final String sponsorName;
  final String title;
  final String subtitle;
  final String priceText;
  final String oldPriceText;
  final String? imagePath;
  final String targetCity;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final bool active;
  final String status;
  final int priority;

  const JoseoSponsoredOffer({
    required this.id,
    required this.sponsorName,
    required this.title,
    required this.subtitle,
    required this.priceText,
    required this.oldPriceText,
    required this.imagePath,
    required this.targetCity,
    required this.startsAt,
    required this.endsAt,
    required this.active,
    required this.status,
    required this.priority,
  });

  factory JoseoSponsoredOffer.fromMap(Map<String, dynamic> row) {
    return JoseoSponsoredOffer(
      id: (row['id'] as num).toInt(),
      sponsorName: row['sponsor_name']?.toString() ?? 'Patrocinador',
      title: row['title']?.toString() ?? 'Oferta patrocinada',
      subtitle: row['subtitle']?.toString() ?? '',
      priceText: row['price_text']?.toString() ?? '',
      oldPriceText: row['old_price_text']?.toString() ?? '',
      imagePath: row['image_path']?.toString(),
      targetCity: row['target_city']?.toString() ?? '',
      startsAt: DateTime.tryParse(row['starts_at']?.toString() ?? ''),
      endsAt: DateTime.tryParse(row['ends_at']?.toString() ?? ''),
      active: row['active'] == true,
      status: row['status']?.toString() ?? 'pending',
      priority: (row['priority'] as num?)?.toInt() ?? 0,
    );
  }

  String? get publicImageUrl {
    final path = imagePath;
    if (path == null || path.trim().isEmpty) return null;
    return Supabase.instance.client.storage
        .from('sponsored-media')
        .getPublicUrl(path);
  }
}

class JoseoCommunityPrice {
  final int priceId;
  final String userId;
  final int productId;
  final String product;
  final int branchId;
  final String branch;
  final int storeId;
  final String supermarket;
  final double price;
  final double? regularPrice;
  final bool isOffer;
  final DateTime? observedAt;
  final String? photoPath;
  final String description;
  final String branchStatus;
  final String storeStatus;
  final int confirmedCount;
  final int incorrectCount;
  final bool verifiedPlace;

  const JoseoCommunityPrice({
    required this.priceId,
    required this.userId,
    required this.productId,
    required this.product,
    required this.branchId,
    required this.branch,
    required this.storeId,
    required this.supermarket,
    required this.price,
    required this.regularPrice,
    required this.isOffer,
    required this.observedAt,
    required this.photoPath,
    required this.description,
    required this.branchStatus,
    required this.storeStatus,
    required this.confirmedCount,
    required this.incorrectCount,
    required this.verifiedPlace,
  });

  factory JoseoCommunityPrice.fromMap(Map<String, dynamic> row) {
    return JoseoCommunityPrice(
      priceId: (row['price_id'] as num).toInt(),
      userId: row['user_id']?.toString() ?? '',
      productId: (row['product_id'] as num).toInt(),
      product: row['product']?.toString() ?? 'Producto',
      branchId: (row['branch_id'] as num).toInt(),
      branch: row['branch']?.toString() ?? 'Sucursal',
      storeId: (row['store_id'] as num).toInt(),
      supermarket: row['supermarket']?.toString() ?? 'Negocio',
      price: (row['price'] as num).toDouble(),
      regularPrice: (row['regular_price'] as num?)?.toDouble(),
      isOffer: row['is_offer'] == true,
      observedAt: DateTime.tryParse(row['observed_at']?.toString() ?? ''),
      photoPath: row['photo_url']?.toString(),
      description: row['description']?.toString() ?? '',
      branchStatus: row['branch_status']?.toString() ?? 'pending',
      storeStatus: row['store_status']?.toString() ?? 'pending',
      confirmedCount: (row['confirmed_count'] as num?)?.toInt() ?? 0,
      incorrectCount: (row['incorrect_count'] as num?)?.toInt() ?? 0,
      verifiedPlace: row['verified_place'] == true,
    );
  }

  String get placeLabel {
    if (branch.toLowerCase() == supermarket.toLowerCase()) {
      return supermarket;
    }
    return '$supermarket • $branch';
  }
}


class JoseoAllPrice {
  final String recordKey;
  final String sourceKind;
  final int? communityPriceId;
  final int? officialPriceId;
  final String userId;
  final int productId;
  final String product;
  final int branchId;
  final String branch;
  final int storeId;
  final String supermarket;
  final double price;
  final double? regularPrice;
  final bool isOffer;
  final DateTime? observedAt;
  final String sourcePeriod;
  final String sourceType;
  final String sourceQuality;
  final String sourceUrl;
  final String sourceDocument;
  final String note;
  final String? photoPath;
  final int confirmedCount;
  final int incorrectCount;
  final bool verifiedPlace;
  final bool canVote;
  final bool xpEligible;
  final bool radarCandidate;
  final double distanceKm;
  final bool isBestNearby;

  const JoseoAllPrice({
    required this.recordKey,
    required this.sourceKind,
    required this.communityPriceId,
    required this.officialPriceId,
    required this.userId,
    required this.productId,
    required this.product,
    required this.branchId,
    required this.branch,
    required this.storeId,
    required this.supermarket,
    required this.price,
    required this.regularPrice,
    required this.isOffer,
    required this.observedAt,
    required this.sourcePeriod,
    required this.sourceType,
    required this.sourceQuality,
    required this.sourceUrl,
    required this.sourceDocument,
    required this.note,
    required this.photoPath,
    required this.confirmedCount,
    required this.incorrectCount,
    required this.verifiedPlace,
    required this.canVote,
    required this.xpEligible,
    required this.radarCandidate,
    required this.distanceKm,
    required this.isBestNearby,
  });

  factory JoseoAllPrice.fromMap(Map<String, dynamic> row) {
    return JoseoAllPrice(
      recordKey: row['record_key']?.toString() ?? '',
      sourceKind: row['source_kind']?.toString() ?? 'community',
      communityPriceId: (row['community_price_id'] as num?)?.toInt(),
      officialPriceId: (row['official_price_id'] as num?)?.toInt(),
      userId: row['user_id']?.toString() ?? '',
      productId: (row['product_id'] as num).toInt(),
      product: row['product']?.toString() ?? 'Producto',
      branchId: (row['branch_id'] as num).toInt(),
      branch: row['branch']?.toString() ?? 'Sucursal',
      storeId: (row['store_id'] as num).toInt(),
      supermarket: row['supermarket']?.toString() ?? 'Negocio',
      price: (row['price'] as num).toDouble(),
      regularPrice: (row['regular_price'] as num?)?.toDouble(),
      isOffer: row['is_offer'] == true,
      observedAt: DateTime.tryParse(row['observed_at']?.toString() ?? ''),
      sourcePeriod: row['source_period']?.toString() ?? '',
      sourceType: row['source_type']?.toString() ?? '',
      sourceQuality: row['source_quality']?.toString() ?? '',
      sourceUrl: row['source_url']?.toString() ?? '',
      sourceDocument: row['source_document']?.toString() ?? '',
      note: row['note']?.toString() ?? '',
      photoPath: row['photo_url']?.toString(),
      confirmedCount: (row['confirmed_count'] as num?)?.toInt() ?? 0,
      incorrectCount: (row['incorrect_count'] as num?)?.toInt() ?? 0,
      verifiedPlace: row['verified_place'] == true,
      canVote: row['can_vote'] == true,
      xpEligible: row['xp_eligible'] == true,
      radarCandidate: row['radar_candidate'] == true,
      distanceKm: (row['distance_km'] as num?)?.toDouble() ?? 0,
      isBestNearby: row['is_best_nearby'] == true,
    );
  }

  bool get isOfficial => sourceKind == 'official';
  bool get isCommunity => sourceKind == 'community';

  String get placeLabel {
    if (branch.toLowerCase() == supermarket.toLowerCase()) {
      return supermarket;
    }
    return '$supermarket • $branch';
  }

  String get sourceLabel => isOfficial ? 'OFICIAL' : 'COMUNIDAD';

  String get dateLabel {
    if (observedAt != null) {
      return JoseoDataService.relativeDate(observedAt);
    }
    if (sourcePeriod.trim().isNotEmpty) {
      return sourcePeriod;
    }
    return 'Fecha no especificada';
  }

  JoseoCommunityPrice? toCommunityPrice() {
    if (!isCommunity || communityPriceId == null) return null;
    return JoseoCommunityPrice(
      priceId: communityPriceId!,
      userId: userId,
      productId: productId,
      product: product,
      branchId: branchId,
      branch: branch,
      storeId: storeId,
      supermarket: supermarket,
      price: price,
      regularPrice: regularPrice,
      isOffer: isOffer,
      observedAt: observedAt,
      photoPath: photoPath,
      description: note,
      branchStatus: verifiedPlace ? 'verified' : 'pending',
      storeStatus: verifiedPlace ? 'verified' : 'pending',
      confirmedCount: confirmedCount,
      incorrectCount: incorrectCount,
      verifiedPlace: verifiedPlace,
    );
  }
}

class JoseoUserStats {
  final int xp;
  final int publishedPrices;
  final int confirmationsMade;
  final int receivedConfirmations;
  final int validatedPrices;
  final int uniqueBranches;

  const JoseoUserStats({
    required this.xp,
    required this.publishedPrices,
    required this.confirmationsMade,
    required this.receivedConfirmations,
    required this.validatedPrices,
    required this.uniqueBranches,
  });

  static const zero = JoseoUserStats(
    xp: 0,
    publishedPrices: 0,
    confirmationsMade: 0,
    receivedConfirmations: 0,
    validatedPrices: 0,
    uniqueBranches: 0,
  );

  bool get firstJoseo => validatedPrices >= 1;
  bool get frequentPublisher => validatedPrices >= 10;
  bool get verifiedHunter => confirmationsMade >= 25;
  bool get storeExplorer => uniqueBranches >= 5;
  bool get communityHeart => xp >= 1000 && receivedConfirmations >= 25;
}

class JoseoDataService {
  JoseoDataService._();

  static final SupabaseClient client = Supabase.instance.client;

  static Future<bool> isAdmin() async {
    if (client.auth.currentUser == null) return false;
    try {
      final result = await client.rpc('joseo_is_admin');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<JoseoSponsoredOffer>> loadSponsoredOffers() async {
    final rows = await client
        .from('sponsored_offers')
        .select(
          'id, sponsor_name, title, subtitle, price_text, old_price_text, '
          'image_path, target_city, starts_at, ends_at, active, status, priority',
        )
        .order('priority', ascending: false)
        .order('created_at', ascending: false)
        .limit(20);

    return rows
        .map(
          (row) => JoseoSponsoredOffer.fromMap(
            Map<String, dynamic>.from(row),
          ),
        )
        .toList();
  }

  static Future<List<JoseoCommunityPrice>> loadCommunityPrices() async {
    final rows = await client
        .from('joseo_community_prices')
        .select(
          'price_id, user_id, product_id, product, branch_id, branch, '
          'store_id, supermarket, price, regular_price, is_offer, '
          'observed_at, photo_url, description, branch_status, store_status, '
          'confirmed_count, incorrect_count, verified_place',
        )
        .order('observed_at', ascending: false)
        .limit(100);

    return rows
        .map(
          (row) => JoseoCommunityPrice.fromMap(
            Map<String, dynamic>.from(row),
          ),
        )
        .toList();
  }


  static Future<List<JoseoAllPrice>> loadNearbyPrices({
    required double latitude,
    required double longitude,
    required double radiusKm,
  }) async {
    final rows = await client.rpc(
      'joseo_prices_nearby',
      params: {
        'p_lat': latitude,
        'p_lng': longitude,
        'p_radius_km': radiusKm,
      },
    );

    return (rows as List)
        .map(
          (row) => JoseoAllPrice.fromMap(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList();
  }

  static Future<void> votePrice({
    required int priceId,
    required String confirmation,
  }) async {
    final user = client.auth.currentUser;
    if (user == null) {
      throw StateError('AUTH_REQUIRED');
    }

    await client.from('price_confirmations').upsert(
      {
        'price_id': priceId,
        'user_id': user.id,
        'confirmation': confirmation,
      },
      onConflict: 'price_id,user_id',
    );
  }


  static Future<void> reportPrice({
    required int priceId,
    required String reason,
    String? details,
  }) async {
    final user = client.auth.currentUser;
    if (user == null) {
      throw StateError('AUTH_REQUIRED');
    }

    await client.rpc(
      'joseo_report_price',
      params: {
        'p_price_id': priceId,
        'p_reason': reason,
        'p_details': details,
      },
    );
  }

  static Future<String?> signedPricePhoto(String? path) async {
    final value = path?.trim() ?? '';
    if (value.isEmpty || client.auth.currentUser == null) return null;

    try {
      return await client.storage
          .from('price-evidence')
          .createSignedUrl(value, 3600);
    } catch (_) {
      return null;
    }
  }

  static Future<JoseoUserStats> loadMyStats() async {
    final user = client.auth.currentUser;
    if (user == null) return JoseoUserStats.zero;

    final pointRows = await client
        .from('user_points')
        .select('points, reason, price_id')
        .eq('user_id', user.id);

    var xp = 0;
    var validatedPrices = 0;

    for (final row in pointRows) {
      xp += (row['points'] as num?)?.toInt() ?? 0;
      if (row['reason']?.toString() == 'price_validated') {
        validatedPrices++;
      }
    }

    final priceRows = await client
        .from('prices')
        .select('id, branch_id')
        .eq('user_id', user.id);

    final priceIds = <int>{};
    final branchIds = <int>{};

    for (final row in priceRows) {
      final id = (row['id'] as num?)?.toInt();
      final branchId = (row['branch_id'] as num?)?.toInt();
      if (id != null) priceIds.add(id);
      if (branchId != null) branchIds.add(branchId);
    }

    final myConfirmationRows = await client
        .from('price_confirmations')
        .select('id')
        .eq('user_id', user.id)
        .eq('confirmation', 'confirmed');

    var receivedConfirmations = 0;
    if (priceIds.isNotEmpty) {
      final allConfirmationRows = await client
          .from('price_confirmations')
          .select('price_id, confirmation');

      for (final row in allConfirmationRows) {
        final priceId = (row['price_id'] as num?)?.toInt();
        if (priceId != null &&
            priceIds.contains(priceId) &&
            row['confirmation']?.toString() == 'confirmed') {
          receivedConfirmations++;
        }
      }
    }

    return JoseoUserStats(
      xp: xp,
      publishedPrices: priceRows.length,
      confirmationsMade: myConfirmationRows.length,
      receivedConfirmations: receivedConfirmations,
      validatedPrices: validatedPrices,
      uniqueBranches: branchIds.length,
    );
  }

  static String relativeDate(DateTime? date) {
    if (date == null) return 'Reciente';
    final difference = DateTime.now().difference(date.toLocal());

    if (difference.inMinutes < 1) return 'Ahora';
    if (difference.inMinutes < 60) {
      return 'Hace ${difference.inMinutes} min';
    }
    if (difference.inHours < 24) {
      return 'Hace ${difference.inHours} h';
    }
    if (difference.inDays < 7) {
      return 'Hace ${difference.inDays} d';
    }

    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year}';
  }
}

// ============================================================
// HOME
// ============================================================

class HomePage extends StatefulWidget {
  final VoidCallback goMap;
  final VoidCallback goOffers;
  final double radiusKm;
  final ValueChanged<double> onRadiusChanged;

  const HomePage({
    super.key,
    required this.goMap,
    required this.goOffers,
    required this.radiusKm,
    required this.onRadiusChanged,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late double _radarRadiusKm;
  late Future<List<JoseoRadarStore>> _radarFuture;

  @override
  void initState() {
    super.initState();
    _radarRadiusKm = widget.radiusKm;
    _radarFuture = _loadRadar();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.radiusKm == _radarRadiusKm) return;

    _radarRadiusKm = widget.radiusKm;
    _radarFuture = _loadRadar();
  }

  void _setRadarRadius(double km) {
    if (_radarRadiusKm == km) return;
    setState(() {
      _radarRadiusKm = km;
      _radarFuture = _loadRadar();
    });
    widget.onRadiusChanged(km);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.25,
            colors: [
              Color(0xFF20105A),
              Color(0xFF080321),
              joseoBg,
            ],
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 110),
          child: Column(
            children: [
              _hero(),
              const SizedBox(height: 16),
              _radarSection(context),
              const SizedBox(height: 20),
              _features(context),
              const SizedBox(height: 24),
              _sponsoredSection(context),
              const SizedBox(height: 24),
              _communityCard(),
              const SizedBox(height: 18),
              _actions(),
              const SizedBox(height: 16),
              const Text(
                'COMPARA, AHORRA, GANA Y AYUDA',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: joseoGold,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  letterSpacing: .4,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '¡Esa es la misión! 🇩🇴',
                style: TextStyle(
                  color: joseoGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hero() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF17053E),
            Color(0xFF0B0225),
          ],
        ),
        border: Border.all(
          color: joseoPurple.withValues(alpha: .45),
        ),
        boxShadow: [
          BoxShadow(
            color: joseoPurple.withValues(alpha: .25),
            blurRadius: 28,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                top: 15,
                left: 25,
                child: _glowDot(
                  12,
                  joseoPurple2.withValues(alpha: .45),
                ),
              ),
              Positioned(
                top: 55,
                right: 20,
                child: _glowDot(
                  9,
                  joseoGreen.withValues(alpha: .40),
                ),
              ),
              const SafeAsset(
                asset: JoseoAssets.logoPortada,
                height: 305,
                fit: BoxFit.contain,
                fallback: Icons.person,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _features(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _feature(
          image: JoseoAssets.compararPrecios,
          title: 'COMPARA\nPRECIOS',
          onTap: widget.goOffers,
        ),
        _feature(
          image: JoseoAssets.recibeAlertas,
          title: 'RECIBE\nALERTAS',
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  '🔔 JOSEO te avisará cuando aparezcan nuevas ofertas.',
                ),
              ),
            );
          },
        ),
        _feature(
          image: JoseoAssets.ganaPuntos,
          title: 'GANA\nPUNTOS',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const GamificationPage(),
              ),
            );
          },
        ),
        _feature(
          image: JoseoAssets.ayudaAhorrar,
          title: 'AYUDA A\nAHORRAR',
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  '💚 Tus aportes ayudan a toda la comunidad JOSEO.',
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _feature({
    required String image,
    required String title,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 78,
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF25144D),
                    Color(0xFF10072C),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: joseoPurple.withValues(alpha: .25),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: SafeAsset(
                asset: image,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 9.5,
                height: 1.08,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<JoseoRadarStore>> _loadRadar() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError(
        'JOSEO necesita permiso de ubicación para calcular el Radar cerca de ti.',
      );
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );

    final rows = await Supabase.instance.client.rpc(
      'joseo_radar_nearby_sources',
      params: {
        'p_lat': position.latitude,
        'p_lng': position.longitude,
        'p_radius_km': _radarRadiusKm,
      },
    );

    return (rows as List)
        .map(
          (row) => JoseoRadarStore.fromMap(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList();
  }

  Widget _radarSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.my_location_rounded, color: joseoGreen, size: 17),
            const SizedBox(width: 7),
            const Expanded(
              child: Text(
                'Radar cerca de ti',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            _radiusChip(10),
            const SizedBox(width: 6),
            _radiusChip(20),
          ],
        ),
        const SizedBox(height: 10),
        FutureBuilder<List<JoseoRadarStore>>(
      future: _radarFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _radarLoadingCard();
        }

        if (snapshot.hasError) {
          return _radarUnavailableCard();
        }

        final allRows = snapshot.data ?? const <JoseoRadarStore>[];
        final publicRows = allRows.where((row) => row.publishable).toList()
          ..sort(
            (a, b) => b.savingsPercent.compareTo(a.savingsPercent),
          );

        if (publicRows.isEmpty) {
          return _radarGatheringCard(allRows);
        }

        return _radarLiveCard(context, publicRows);
      },
        ),
      ],
    );
  }

  Widget _radiusChip(double km) {
    final selected = _radarRadiusKm == km;
    return InkWell(
      onTap: () => _setRadarRadius(km),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? joseoGreen.withValues(alpha: .16)
              : Colors.white.withValues(alpha: .04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? joseoGreen : Colors.white12,
          ),
        ),
        child: Text(
          '${km.toInt()} km',
          style: TextStyle(
            color: selected ? joseoGreen : Colors.white54,
            fontSize: 9.5,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _radarLoadingCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF153E2C),
            Color(0xFF10153A),
          ],
        ),
        border: Border.all(
          color: joseoGreen.withValues(alpha: .38),
        ),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: joseoGreen,
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Calculando el Radar JOSEO con datos comunitarios y precios web oficiales...',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _radarUnavailableCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: joseoPurple.withValues(alpha: .35),
        ),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.radar_rounded, color: joseoGreen),
              SizedBox(width: 8),
              Text(
                'RADAR JOSEO',
                style: TextStyle(
                  color: joseoGreen,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .8,
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Text(
            'El índice no está disponible en este momento.',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Tus precios siguen funcionando. JOSEO volverá a calcular el Radar cuando pueda consultar Supabase.',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _radarGatheringCard(List<JoseoRadarStore> rows) {
    var webProducts = 0;
    var communityProducts = 0;
    var comparableProducts = 0;

    for (final row in rows) {
      if (row.webProductCount > webProducts) {
        webProducts = row.webProductCount;
      }
      if (row.communityProductCount > communityProducts) {
        communityProducts = row.communityProductCount;
      }
      if (row.comparableProductCount > comparableProducts) {
        comparableProducts = row.comparableProductCount;
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF173C2A),
            Color(0xFF11143B),
            Color(0xFF25104D),
          ],
        ),
        border: Border.all(
          color: joseoGreen.withValues(alpha: .52),
        ),
        boxShadow: [
          BoxShadow(
            color: joseoGreen.withValues(alpha: .12),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: joseoGreen.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.radar_rounded,
                  color: joseoGreen,
                  size: 29,
                ),
              ),
              const SizedBox(width: 11),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'RADAR JOSEO',
                      style: TextStyle(
                        color: joseoGreen,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .9,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '¿Dónde está más barato?',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              _radarChip('EN FORMACIÓN', joseoGold),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Aún reuniendo datos confiables',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'JOSEO mostrará qué sucursal cercana está porcentualmente más económica cuando existan suficientes productos comparables y señales de confiabilidad dentro de ${_radarRadiusKm.toInt()} km.',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              height: 1.35,
            ),
          ),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _radarMetric(
                    '$webProducts',
                    'Precios web\ncercanos',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _radarMetric(
                    '$communityProducts',
                    'Productos\ncomunidad',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _radarMetric(
                    '$comparableProducts',
                    'Comparables\nlocales',
                  ),
                ),
              ],
            ),
          ],
          if (rows.any(
            (row) =>
                row.webProductCount > 0 || row.communityProductCount > 0,
          )) ...[
            const SizedBox(height: 14),
            const Text(
              'Datos cercanos disponibles',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 7),
            ...rows
                .where(
                  (row) =>
                      row.webProductCount > 0 ||
                      row.communityProductCount > 0,
                )
                .take(5)
                .map(_radarSourceRow),
          ],
          const SizedBox(height: 14),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 11),
          const Text(
            'ℹ️ Índice estimado con precios comunitarios recientes y precios web oficiales. No se publica un porcentaje hasta alcanzar el nivel mínimo de confianza.',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 9.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _radarSourceRow(JoseoRadarStore row) {
    final label = row.branchName.trim().isEmpty
        ? row.supermarket
        : '${row.supermarket} • ${row.branchName}';
    final details = <String>[
      '${row.distanceKm.toStringAsFixed(1)} km',
      if (row.webProductCount > 0) '${row.webProductCount} precios web',
      if (row.communityProductCount > 0)
        '${row.communityProductCount} productos comunidad',
    ].join(' • ');

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.storefront_outlined, color: joseoGreen, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'EN FORMACIÓN',
            style: TextStyle(
              color: joseoGold,
              fontSize: 7.5,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _radarLiveCard(
    BuildContext context,
    List<JoseoRadarStore> rows,
  ) {
    final top = rows.first;
    final topLabel = top.branchName.trim().isEmpty
        ? top.supermarket
        : '${top.supermarket} • ${top.branchName}';
    final positive = top.savingsPercent > 0.05;
    final nearAverage = top.savingsPercent.abs() <= 0.05;

    final String headline;
    if (positive) {
      headline =
          '$topLabel está ${top.savingsPercent.toStringAsFixed(1)}% más económico';
    } else if (nearAverage) {
      headline = '$topLabel está prácticamente en el promedio JOSEO';
    } else {
      headline =
          '$topLabel es el más competitivo de los datos disponibles';
    }

    final updated = top.updatedAt == null
        ? 'Actualizado recientemente'
        : 'Actualizado ${top.updatedAt!.toLocal().day.toString().padLeft(2, '0')}/'
            '${top.updatedAt!.toLocal().month.toString().padLeft(2, '0')} '
            '${top.updatedAt!.toLocal().hour.toString().padLeft(2, '0')}:'
            '${top.updatedAt!.toLocal().minute.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0B5A35),
            Color(0xFF103B43),
            Color(0xFF23104A),
          ],
        ),
        border: Border.all(
          color: joseoGreen.withValues(alpha: .68),
        ),
        boxShadow: [
          BoxShadow(
            color: joseoGreen.withValues(alpha: .16),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: joseoGreen,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.radar_rounded,
                  color: Colors.black,
                  size: 31,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'RADAR JOSEO',
                      style: TextStyle(
                        color: joseoGreen,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .9,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      updated,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 9.5,
                      ),
                    ),
                  ],
                ),
              ),
              _radarChip(
                'CONFIANZA ${top.confidence.toUpperCase()}',
                top.confidence == 'alta' ? joseoGreen : joseoGold,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            headline,
            style: const TextStyle(
              fontSize: 22,
              height: 1.05,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            positive
                ? 'frente a la referencia calculada con los mismos productos comparables dentro de ${_radarRadiusKm.toInt()} km.'
                : 'según los productos comparables disponibles dentro de ${_radarRadiusKm.toInt()} km.',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 15),
          ...rows.take(3).toList().asMap().entries.map((entry) {
            final position = entry.key + 1;
            final row = entry.value;
            final medal = switch (position) {
              1 => '🥇',
              2 => '🥈',
              _ => '🥉',
            };

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Text(
                      medal,
                      style: const TextStyle(fontSize: 19),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        row.supermarket,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                    Text(
                      row.savingsPercent >= 0
                          ? '${row.savingsPercent.toStringAsFixed(1)}% menos'
                          : '${row.savingsPercent.abs().toStringAsFixed(1)}% más',
                      style: TextStyle(
                        color: row.savingsPercent >= 0
                            ? joseoGreen
                            : joseoGold,
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _radarMetric(
                  '${top.comparableProductCount}',
                  'Productos\ncomparables',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _radarMetric(
                  '${top.contributionCount}',
                  'Usuarios\ndistintos',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _radarMetric(
                  '${top.confirmationCount}',
                  'Confirmaciones',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 10),
          const Text(
            'ℹ️ Cálculo híbrido: usa precios comunitarios recientes y precios web oficiales, productos equivalentes, señales de confirmación y filtros de valores extremos. Puede variar por sucursal, fecha y disponibilidad.',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 9.3,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.goOffers,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(
                  color: joseoGreen.withValues(alpha: .65),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.compare_arrows_rounded),
              label: const Text(
                'Ver precios comparados',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _radarMetric(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 7,
        vertical: 9,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: joseoGreen,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 8.5,
              height: 1.15,
            ),
          ),
        ],
      ),
    );
  }

  Widget _radarChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: color.withValues(alpha: .52),
        ),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: .3,
        ),
      ),
    );
  }

  Widget _sponsoredSection(BuildContext context) {
    return FutureBuilder<List<JoseoSponsoredOffer>>(
      future: JoseoDataService.loadSponsoredOffers(),
      builder: (context, snapshot) {
        final offers = snapshot.data ?? const <JoseoSponsoredOffer>[];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ofertas patrocinadas',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Promociones pagadas, siempre identificadas.',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: joseoGold.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: joseoGold.withValues(alpha: .5),
                    ),
                  ),
                  child: const Text(
                    'PUBLICIDAD',
                    style: TextStyle(
                      color: joseoGold,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (snapshot.connectionState == ConnectionState.waiting)
              const SizedBox(
                height: 150,
                child: Center(
                  child: CircularProgressIndicator(color: joseoGold),
                ),
              )
            else if (offers.isEmpty)
              _sponsoredEmptyCard(context)
            else
              SizedBox(
                height: 214,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: offers.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    return _sponsoredOfferCard(context, offers[index]);
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _sponsoredEmptyCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: joseoGold.withValues(alpha: .28)),
      ),
      child: const Row(
        children: [
          Icon(Icons.campaign_outlined, color: joseoGold, size: 34),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Espacio disponible para patrocinadores',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                SizedBox(height: 3),
                Text(
                  'Las campañas aprobadas por JOSEO aparecerán aquí sin mezclarse con los precios de la comunidad.',
                  style: TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sponsoredOfferCard(
    BuildContext context,
    JoseoSponsoredOffer offer,
  ) {
    final imageUrl = offer.publicImageUrl;

    return Container(
      width: 295,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF2C164D),
            Color(0xFF101B3F),
          ],
        ),
        border: Border.all(color: joseoGold.withValues(alpha: .42)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: joseoGold.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: imageUrl == null
                    ? const Icon(Icons.storefront_rounded, color: joseoGold)
                    : Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.storefront_rounded,
                          color: joseoGold,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offer.sponsorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'PATROCINADO',
                      style: TextStyle(
                        color: joseoGold,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .6,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            offer.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 3),
          Text(
            offer.subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 10),
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (offer.priceText.isNotEmpty)
                      Text(
                        offer.priceText,
                        style: const TextStyle(
                          color: joseoGreen,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    if (offer.oldPriceText.isNotEmpty)
                      Text(
                        offer.oldPriceText,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 9,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                  ],
                ),
              ),
              if (offer.targetCity.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    offer.targetCity,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 8.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _communityCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF25104D),
            Color(0xFF120530),
            Color(0xFF071C4C),
          ],
        ),
        border: Border.all(
          color: joseoPurple2.withValues(alpha: .45),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .35),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            Positioned(
              right: 18,
              top: 26,
              child: _glowDot(
                10,
                joseoGold.withValues(alpha: .65),
              ),
            ),
            Positioned(
              right: 50,
              top: 55,
              child: _glowDot(
                7,
                joseoPurple2.withValues(alpha: .65),
              ),
            ),
            Positioned(
              left: 16,
              bottom: 80,
              child: const SafeAsset(
                asset: JoseoAssets.moneda1,
                width: 34,
                height: 34,
              ),
            ),
            Positioned(
              right: 14,
              bottom: 105,
              child: const SafeAsset(
                asset: JoseoAssets.moneda3,
                width: 38,
                height: 38,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                16,
                18,
                16,
                12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '¡ÚNETE A LA COMUNIDAD\nQUE AHORRA MÁS!',
                    style: TextStyle(
                      fontSize: 18,
                      height: 1.05,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Encuentra, compara y comparte precios reales.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: SizedBox(
                      height: 260,
                      child: const SafeAsset(
                        asset: JoseoAssets.joseCarrito,
                        width: 280,
                        height: 260,
                        fit: BoxFit.contain,
                        fallback: Icons.shopping_cart,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: widget.goOffers,
            style: ElevatedButton.styleFrom(
              backgroundColor: joseoGreen,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(
                vertical: 14,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            icon: const SafeAsset(
              asset: JoseoAssets.llamita,
              width: 24,
              height: 24,
              fallback: Icons.local_fire_department,
            ),
            label: const Text(
              'Ver ofertas',
              style: TextStyle(
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: widget.goMap,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                vertical: 14,
              ),
              side: BorderSide(
                color: joseoPurple2.withValues(alpha: .8),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            icon: const SafeAsset(
              asset: JoseoAssets.pinLocalizacion,
              width: 24,
              height: 24,
              fallback: Icons.location_on,
            ),
            label: const Text(
              'Explorar mapa',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _glowDot(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color,
            blurRadius: 12,
            spreadRadius: 3,
          ),
        ],
      ),
    );
  }
}
class StoreBubble extends StatelessWidget {
  final String text;
  final Color color;

  const StoreBubble({
    super.key,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 8,
            backgroundColor: color,
            child: const Icon(
              Icons.store,
              color: Colors.white,
              size: 10,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 9,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// MAPA COMUNITARIO JOSEO
// ============================================================

class MapPage extends StatefulWidget {
  final double radiusKm;
  final ValueChanged<double> onRadiusChanged;

  const MapPage({
    super.key,
    required this.radiusKm,
    required this.onRadiusChanged,
  });

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  static const LatLng _puntaCanaFallback = LatLng(18.5820, -68.4055);

  bool map = true;
  bool _loading = true;
  String? _error;
  Position? _position;
  final MapController _mapController = MapController();
  LatLng? _pendingMapTarget;

  List<JoseoBranchOption> _branches = const [];
  Map<int, JoseoCommunityPrice> _latestPriceByBranch = const {};

  @override
  void initState() {
    super.initState();
    _loadRealMap();
  }

  @override
  void didUpdateWidget(covariant MapPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.radiusKm == widget.radiusKm) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadRealMap();
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadRealMap() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw StateError(
          'Activa la ubicación del teléfono para ver supermercados cerca de ti.',
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError(
          'JOSEO necesita permiso de ubicación para centrar el mapa y calcular distancias.',
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final client = Supabase.instance.client;

      List<dynamic> storeRows = const [];
      List<dynamic> branchRows = const [];
      List<JoseoCommunityPrice> prices = const [];

      try {
        final results = await Future.wait<dynamic>([
          client
              .from('stores')
              .select('id, name, active, verification_status'),
          client.from('branches').select(
                'id, store_id, name, address, city, province, latitude, '
                'longitude, active, verification_status',
              ),
          JoseoDataService.loadCommunityPrices(),
        ]);

        storeRows = results[0] as List<dynamic>;
        branchRows = results[1] as List<dynamic>;
        prices = results[2] as List<JoseoCommunityPrice>;
      } catch (error) {
        debugPrint('JOSEO sucursales del mapa: $error');
      }

      final storeNames = <int, String>{};
      final verifiedStoreIds = <int>{};

      for (final raw in storeRows) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = (row['id'] as num?)?.toInt();
        if (id == null) continue;

        storeNames[id] = row['name']?.toString() ?? 'Negocio';

        if (row['active'] == true &&
            row['verification_status']?.toString() == 'verified') {
          verifiedStoreIds.add(id);
        }
      }

      final branches = <JoseoBranchOption>[];

      for (final raw in branchRows) {
        final row = Map<String, dynamic>.from(raw as Map);
        final storeId = (row['store_id'] as num?)?.toInt();
        final latitude = (row['latitude'] as num?)?.toDouble();
        final longitude = (row['longitude'] as num?)?.toDouble();

        if (storeId == null ||
            latitude == null ||
            longitude == null ||
            row['active'] != true ||
            row['verification_status']?.toString() != 'verified' ||
            !verifiedStoreIds.contains(storeId)) {
          continue;
        }

        final distance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          latitude,
          longitude,
        );

        if (distance > widget.radiusKm * 1000) {
          continue;
        }

        branches.add(
          JoseoBranchOption(
            id: (row['id'] as num).toInt(),
            storeId: storeId,
            storeName: storeNames[storeId] ?? 'Negocio',
            branchName: row['name']?.toString() ?? 'Sucursal',
            address: row['address']?.toString() ?? '',
            city: row['city']?.toString() ?? '',
            province: row['province']?.toString() ?? '',
            latitude: latitude,
            longitude: longitude,
            active: true,
            verificationStatus: 'verified',
            distanceMeters: distance,
          ),
        );
      }

      branches.sort(
        (a, b) => (a.distanceMeters ?? double.infinity)
            .compareTo(b.distanceMeters ?? double.infinity),
      );

      final latestByBranch = <int, JoseoCommunityPrice>{};
      for (final price in prices) {
        if (!price.verifiedPlace) continue;

        final current = latestByBranch[price.branchId];
        if (current == null) {
          latestByBranch[price.branchId] = price;
          continue;
        }

        final currentDate =
            current.observedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final candidateDate =
            price.observedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

        if (candidateDate.isAfter(currentDate)) {
          latestByBranch[price.branchId] = price;
        }
      }

      if (!mounted) return;

      setState(() {
        _position = position;
        _branches = branches;
        _latestPriceByBranch = latestByBranch;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('StateError: ', '');
      });
    }
  }

  Future<void> _centerOnUser() async {
    final position = _position;
    if (position == null) return;

    try {
      _mapController.move(
        LatLng(position.latitude, position.longitude),
        widget.radiusKm == 10 ? 11.4 : 10.6,
      );
    } catch (error) {
      debugPrint('JOSEO: no se pudo centrar el mapa: $error');
    }
  }

  JoseoBranchOption? get _nearestBranch {
    if (_branches.isEmpty) return null;
    return _branches.first;
  }

  String _distanceLabel(double? meters) {
    if (meters == null) return 'Distancia no disponible';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  List<Marker> get _markers {
    final nearestId = _nearestBranch?.id;
    final markers = <Marker>[];

    markers.addAll(_branches.map((branch) {
      final price = _latestPriceByBranch[branch.id];
      final isNearest = branch.id == nearestId;

      return Marker(
        point: LatLng(branch.latitude!, branch.longitude!),
        width: 52,
        height: 52,
        child: GestureDetector(
          onTap: () => _showBranchDetails(branch),
          child: Icon(
            Icons.location_on,
            size: 44,
            color: isNearest ? Colors.blueAccent : joseoGreen,
            shadows: const [
              Shadow(color: Colors.black54, blurRadius: 4),
            ],
          ),
        ),
      );
    }));

    return markers;
  }

  List<CircleMarker> get _radiusCircle {
    final position = _position;
    if (position == null) return const <CircleMarker>[];

    return [
      CircleMarker(
        point: LatLng(position.latitude, position.longitude),
        radius: widget.radiusKm * 1000,
        useRadiusInMeter: true,
        color: joseoPurple.withValues(alpha: .06),
        borderColor: joseoPurple2.withValues(alpha: .55),
        borderStrokeWidth: 2,
      ),
    ];
  }

  Future<void> _showBranchDetails(JoseoBranchOption branch) async {
    final allPrices = await JoseoDataService.loadCommunityPrices();

    final branchPrices = allPrices
        .where(
          (item) =>
              item.branchId == branch.id &&
              item.verifiedPlace,
        )
        .toList()
      ..sort((a, b) {
        final ad = a.observedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bd = b.observedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bd.compareTo(ad);
      });

    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: joseoCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const JoseoShoppingListPage(),
                        ),
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF164B31), Color(0xFF1D1245)],
                        ),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: joseoGreen.withValues(alpha: .48)),
                      ),
                      child: const Row(
                        children: [
                          CircleAvatar(
                            radius: 25,
                            backgroundColor: Color(0x2286E019),
                            child: Icon(
                              Icons.checklist_rounded,
                              color: joseoGreen,
                              size: 29,
                            ),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Mi lista de compras',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  'Anota, lleva al supermercado y marca lo que ya compraste.',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: joseoGreen),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const CircleAvatar(
                      radius: 22,
                      backgroundColor: Color(0x2215FF00),
                      child: Icon(
                        Icons.storefront_rounded,
                        color: joseoGreen,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            branch.storeName,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            branch.branchName,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: joseoGreen.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: joseoGreen.withValues(alpha: .45),
                        ),
                      ),
                      child: Text(
                        _distanceLabel(branch.distanceMeters),
                        style: const TextStyle(
                          color: joseoGreen,
                          fontWeight: FontWeight.w900,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
                if (branch.address.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    branch.address,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 10.5,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Precios recientes',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                if (branchPrices.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: joseoBg2,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Text(
                      'Todavía no hay precios recientes publicados para esta sucursal.',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 10.5,
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(sheetContext).size.height * .42,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: branchPrices.length > 8
                          ? 8
                          : branchPrices.length,
                      separatorBuilder: (context, index) =>
                          const Divider(color: Colors.white10),
                      itemBuilder: (context, index) {
                        final item = branchPrices[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(
                            Icons.local_offer_outlined,
                            color: joseoGold,
                          ),
                          title: Text(
                            item.product,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                          subtitle: Text(
                            JoseoDataService.relativeDate(item.observedAt),
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 9,
                            ),
                          ),
                          trailing: Text(
                            'RD\$ ${item.price.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: joseoGreen,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                const SizedBox(width: 38),
                const Expanded(
                  child: Text(
                    'Mapa de ofertas',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Actualizar ubicación',
                  onPressed: _loading ? null : _loadRealMap,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Container(
            width: 210,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: joseoCard,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: joseoPurple.withValues(alpha: .28),
              ),
            ),
            child: Row(
              children: [
                _toggleButton('Mapa', true),
                _toggleButton('Lista', false),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Buscar alrededor:',
                style: TextStyle(color: Colors.white60, fontSize: 10.5),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('10 km'),
                selected: widget.radiusKm == 10,
                onSelected: _loading
                    ? null
                    : (selected) {
                        if (!selected || widget.radiusKm == 10) return;
                        widget.onRadiusChanged(10);
                      },
              ),
              const SizedBox(width: 7),
              ChoiceChip(
                label: const Text('20 km'),
                selected: widget.radiusKm == 20,
                onSelected: _loading
                    ? null
                    : (selected) {
                        if (!selected || widget.radiusKm == 20) return;
                        widget.onRadiusChanged(20);
                      },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: joseoGreen),
                  )
                : _error != null
                    ? _errorView()
                    : map
                        ? _mapView()
                        : _listView(),
          ),
        ],
      ),
    );
  }

  Widget _toggleButton(String text, bool value) {
    final selected = map == value;

    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            map = value;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? joseoGreen : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: joseoGreen.withValues(alpha: .25),
                      blurRadius: 12,
                    ),
                  ]
                : null,
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white70,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.location_off_outlined,
              color: joseoGold,
              size: 52,
            ),
            const SizedBox(height: 14),
            const Text(
              'No pudimos cargar tu ubicación',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Inténtalo nuevamente.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white60,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadRealMap,
              style: FilledButton.styleFrom(
                backgroundColor: joseoGreen,
                foregroundColor: Colors.black,
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mapView() {
    final position = _position;
    final target = position == null
        ? _puntaCanaFallback
        : LatLng(position.latitude, position.longitude);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .40),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: target,
                initialZoom: widget.radiusKm == 10 ? 11.4 : 10.6,
                onMapReady: () {
                  if (!mounted) return;

                  final pendingTarget = _pendingMapTarget;
                  _pendingMapTarget = null;

                  if (pendingTarget != null) {
                    _mapController.move(pendingTarget, 16.5);
                  } else {
                    _centerOnUser();
                  }
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.alqanza.joseo',
                ),
                CircleLayer(circles: _radiusCircle),
                MarkerLayer(markers: _markers),
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            right: 12,
            top: 12,
            child: FloatingActionButton.small(
              heroTag: 'joseo_map_location',
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              onPressed: _centerOnUser,
              child: const Icon(Icons.my_location),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: _proximityCard(),
          ),
        ],
      ),
    );
  }

  Widget _proximityCard() {
    final nearest = _nearestBranch;

    if (nearest == null) {
      return Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: joseoCard.withValues(alpha: .95),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: joseoPurple2.withValues(alpha: .45),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.store_mall_directory_outlined, color: joseoGold),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Todavía no hay negocios JOSEO verificados en este radio. '
                'Puedes registrar uno al momento de publicar un precio.',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 10.5,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final meters = nearest.distanceMeters ?? double.infinity;
    final veryClose = meters <= 250;
    final price = _latestPriceByBranch[nearest.id];

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 11, 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [
            Color(0xFF13082F),
            Color(0xFF24104B),
          ],
        ),
        border: Border.all(
          color: veryClose
              ? joseoGreen.withValues(alpha: .75)
              : joseoPurple2.withValues(alpha: .45),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .40),
            blurRadius: 16,
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            veryClose ? Icons.near_me : Icons.storefront_rounded,
            color: veryClose ? joseoGreen : joseoGold,
            size: 36,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  veryClose
                      ? 'Estás en/cerca de ${nearest.storeName}'
                      : 'Más cercano: ${nearest.storeName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${nearest.branchName} • ${_distanceLabel(meters)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 9.5,
                  ),
                ),
                if (price != null)
                  Text(
                    '${price.product} • RD\$ ${price.price.toStringAsFixed(2)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: joseoGreen,
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                map = false;
              });
            },
            child: const Text(
              'Ver lista',
              style: TextStyle(
                color: joseoGreen,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _listView() {
    if (_branches.isEmpty) {
      return const Center(
        child: Text(
          'No encontramos negocios JOSEO verificados en el radio seleccionado.\n'
          'Puedes agregar uno desde el formulario de publicar precio.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white60),
        ),
      );
    }

    return RefreshIndicator(
      color: joseoGreen,
      onRefresh: _loadRealMap,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
        children: [
          if (_branches.isNotEmpty) ...[
            _placeSectionTitle(
              'Sucursales JOSEO',
              'Verificadas y con precios comunitarios',
              joseoGreen,
            ),
            ..._branches.asMap().entries.map(
                  (entry) => _branchListCard(entry.value, entry.key == 0),
                ),
          ],
        ],
      ),
    );
  }

  Widget _placeSectionTitle(String title, String subtitle, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(
        children: [
          Icon(Icons.location_on, color: color, size: 20),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.white54, fontSize: 9.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _branchListCard(JoseoBranchOption branch, bool nearest) {
    final price = _latestPriceByBranch[branch.id];
    return _placeCard(
      title: branch.displayName,
      subtitle: _distanceLabel(branch.distanceMeters),
      detail: price == null
          ? 'Sucursal verificada en JOSEO'
          : '${price.product} • RD\$ ${price.price.toStringAsFixed(2)}',
      color: nearest ? joseoGreen : joseoPurple2,
      icon: Icons.verified_outlined,
      onTap: () => _focusOnMap(
        LatLng(branch.latitude!, branch.longitude!),
      ),
    );
  }

  Widget _placeCard({
    required String title,
    required String subtitle,
    required String detail,
    required Color color,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: color.withValues(alpha: .32)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 23,
            backgroundColor: color.withValues(alpha: .14),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: color == joseoGold ? joseoGold : joseoGreen,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 9.5),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Ver en mapa',
            onPressed: onTap,
            icon: Icon(Icons.location_on_outlined, color: color),
          ),
        ],
      ),
    );
  }

  Future<void> _focusOnMap(LatLng target) async {
    // Cambiamos a la vista de mapa y enfocamos el marcador después del frame.
    setState(() {
      _pendingMapTarget = target;
      map = true;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pendingTarget = _pendingMapTarget;
      if (pendingTarget == null) return;
      _pendingMapTarget = null;
      _mapController.move(pendingTarget, 16.5);
    });
  }
}

class JoseoMapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final road = Paint()
      ..color = Colors.white.withValues(alpha: .65)
      ..strokeWidth = 5;

    final road2 = Paint()
      ..color = Colors.white.withValues(alpha: .35)
      ..strokeWidth = 3;

    final water = Paint()
      ..color = const Color(0xFF4BC1DF);

    canvas.drawRect(
      Rect.fromLTWH(
        size.width * .72,
        0,
        size.width * .28,
        size.height,
      ),
      water,
    );

    canvas.drawLine(
      Offset(0, size.height * .25),
      Offset(size.width, size.height * .4),
      road,
    );

    canvas.drawLine(
      Offset(0, size.height * .65),
      Offset(size.width, size.height * .5),
      road,
    );

    canvas.drawLine(
      Offset(size.width * .35, 0),
      Offset(size.width * .45, size.height),
      road,
    );

    canvas.drawLine(
      Offset(size.width * .1, 0),
      Offset(size.width * .15, size.height),
      road2,
    );
  }

  @override
  bool shouldRepaint(
    covariant CustomPainter oldDelegate,
  ) =>
      false;
}

class MapCircleButton extends StatelessWidget {
  final String asset;
  final IconData icon;

  const MapCircleButton({
    super.key,
    required this.asset,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      padding: const EdgeInsets.all(5),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
      ),
      child: SafeAsset(
        asset: asset,
        fallback: icon,
      ),
    );
  }
}

class MapOfferCard extends StatelessWidget {
  final String store;
  final String product;
  final String price;
  final Color color;

  const MapOfferCard({
    super.key,
    required this.store,
    required this.product,
    required this.price,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 165,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color,
            child: const Icon(
              Icons.store,
              color: Colors.white,
              size: 17,
            ),
          ),

          const SizedBox(width: 7),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  store,
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                Text(
                  product,
                  style: const TextStyle(
                    color: Colors.black54,
                    fontSize: 8,
                  ),
                ),
                Text(
                  price,
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class OfferListCard extends StatelessWidget {
  final String store;
  final String product;
  final String price;
  final String distance;
  final Color color;

  const OfferListCard({
    super.key,
    required this.store,
    required this.product,
    required this.price,
    required this.distance,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color,
            child: const Icon(
              Icons.store,
              color: Colors.white,
            ),
          ),

          const SizedBox(width: 11),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  store,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  product,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                  ),
                ),
                Text(
                  distance,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          Text(
            price,
            style: const TextStyle(
              color: joseoGreen,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// OFERTAS / PRECIOS REALES DE LA COMUNIDAD
// ============================================================

class OffersPage extends StatefulWidget {
  final double radiusKm;
  final ValueChanged<double> onRadiusChanged;

  const OffersPage({
    super.key,
    required this.radiusKm,
    required this.onRadiusChanged,
  });

  @override
  State<OffersPage> createState() => _OffersPageState();
}

class _OffersPageState extends State<OffersPage> {
  int selectedFilter = 0;
  final _searchController = TextEditingController();
  final filters = const [
    'Todos',
    'Ofertas',
    'Oficiales',
    'Comunidad',
    'Por confirmar',
  ];

  late Future<List<JoseoAllPrice>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant OffersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.radiusKm == widget.radiusKm) return;
    _refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _refresh() {
    _future = _loadNearbyPrices();
  }

  Future<List<JoseoAllPrice>> _loadNearbyPrices() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw StateError(
        'Activa la ubicación del teléfono para comparar precios cerca de ti.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError(
        'JOSEO necesita permiso de ubicación para mostrar precios de tu zona.',
      );
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );

    return JoseoDataService.loadNearbyPrices(
      latitude: position.latitude,
      longitude: position.longitude,
      radiusKm: widget.radiusKm,
    );
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(_refresh);
    await _future;
  }

  List<JoseoAllPrice> _applyFilter(List<JoseoAllPrice> rows) {
    List<JoseoAllPrice> filtered;

    switch (selectedFilter) {
      case 1:
        filtered = rows.where((row) => row.isOffer).toList();
        break;
      case 2:
        filtered = rows.where((row) => row.isOfficial).toList();
        break;
      case 3:
        filtered = rows.where((row) => row.isCommunity).toList();
        break;
      case 4:
        filtered = rows
            .where(
              (row) =>
                  row.isCommunity &&
                  (row.confirmedCount < 2 || row.incorrectCount > 0),
            )
            .toList();
        break;
      default:
        filtered = List<JoseoAllPrice>.from(rows);
    }

    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      filtered = filtered
          .where(
            (row) =>
                row.product.toLowerCase().contains(query) ||
                row.supermarket.toLowerCase().contains(query) ||
                row.branch.toLowerCase().contains(query),
          )
          .toList();
    }

    filtered.sort((a, b) {
      final productOrder =
          a.product.toLowerCase().compareTo(b.product.toLowerCase());
      if (productOrder != 0) return productOrder;

      if (a.isBestNearby != b.isBestNearby) {
        return a.isBestNearby ? -1 : 1;
      }

      final priceOrder = a.price.compareTo(b.price);
      if (priceOrder != 0) return priceOrder;

      return a.distanceKm.compareTo(b.distanceKm);
    });

    return filtered;
  }

  Widget _offersRadiusChip(double km) {
    final selected = widget.radiusKm == km;

    return InkWell(
      onTap: selected ? null : () => widget.onRadiusChanged(km),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? joseoGreen : Colors.black.withValues(alpha: .18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? joseoGreen
                : joseoPurple.withValues(alpha: .35),
          ),
        ),
        child: Text(
          '${km.toInt()} km',
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontSize: 10,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D062A), joseoBg],
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  const SafeAsset(
                    asset: JoseoAssets.compararPrecios,
                    width: 40,
                    height: 40,
                    fallback: Icons.compare_arrows_rounded,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Precios en JOSEO',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          'Compara únicamente negocios cercanos y encuentra el precio más bajo.',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                decoration: BoxDecoration(
                  color: joseoCard,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: joseoGreen.withValues(alpha: .30),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.my_location_rounded,
                          color: joseoGreen,
                          size: 17,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            'Precios dentro de ${widget.radiusKm.toInt()} km',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        _offersRadiusChip(10),
                        const SizedBox(width: 6),
                        _offersRadiusChip(20),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(fontSize: 12),
                      decoration: InputDecoration(
                        hintText: 'Buscar producto o negocio',
                        hintStyle: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: joseoGreen,
                          size: 20,
                        ),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                                icon: const Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                ),
                              ),
                        filled: true,
                        fillColor: Colors.black.withValues(alpha: .18),
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                itemCount: filters.length,
                itemBuilder: (context, index) {
                  final active = selectedFilter == index;
                  return GestureDetector(
                    onTap: () => setState(() => selectedFilter = index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: active ? joseoGreen : joseoCard,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: active
                              ? joseoGreen
                              : joseoPurple.withValues(alpha: .25),
                        ),
                      ),
                      child: Text(
                        filters[index],
                        style: TextStyle(
                          color: active ? Colors.black : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<JoseoAllPrice>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: joseoGreen),
                    );
                  }

                  if (snapshot.hasError) {
                    return _offersError(snapshot.error);
                  }

                  final rows = _applyFilter(
                    snapshot.data ?? const <JoseoAllPrice>[],
                  );

                  if (rows.isEmpty) {
                    return _offersEmpty();
                  }

                  return RefreshIndicator(
                    color: joseoGreen,
                    onRefresh: _reload,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 110),
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final item = rows[index];
                        final showProductHeader = index == 0 ||
                            rows[index - 1].productId != item.productId;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showProductHeader)
                              Padding(
                                padding: EdgeInsets.fromLTRB(
                                  4,
                                  index == 0 ? 4 : 14,
                                  4,
                                  8,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.shopping_basket_outlined,
                                      color: joseoGreen,
                                      size: 17,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        item.product,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      'Comparación cercana',
                                      style: TextStyle(
                                        color: joseoGreen.withValues(alpha: .85),
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            _JoseoAllPriceCard(
                              item: item,
                              onTap: () async {
                                if (item.isOfficial) {
                                  await Navigator.push<void>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          JoseoOfficialPriceDetailPage(
                                        price: item,
                                      ),
                                    ),
                                  );
                                  return;
                                }

                                final community = item.toCommunityPrice();
                                if (community == null) return;

                                final changed = await Navigator.push<bool>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => JoseoPriceDetailPage(
                                      price: community,
                                    ),
                                  ),
                                );

                                if (changed == true && mounted) {
                                  _reload();
                                }
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _offersError(Object? error) {
    final rawMessage = error
        .toString()
        .replaceFirst('Bad state: ', '')
        .replaceFirst('StateError: ', '');
    final message = rawMessage.contains('joseo_prices_nearby') ||
            rawMessage.contains('PGRST202')
        ? 'Falta instalar JOSEO_precios_geolocalizados.sql en Supabase.'
        : rawMessage;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48, color: joseoGold),
            const SizedBox(height: 10),
            Text(
              message.isEmpty ? 'No pudimos cargar los precios.' : message,
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _reload,
              child: const Text('Intentar otra vez'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _offersEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SafeAsset(
              asset: JoseoAssets.joseLupa,
              width: 120,
              height: 120,
              fallback: Icons.search_rounded,
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.trim().isNotEmpty
                  ? 'No encontramos ese producto dentro de ${widget.radiusKm.toInt()} km.'
                  : 'Todavía no tenemos precios disponibles dentro de ${widget.radiusKm.toInt()} km.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 7),
            const Text(
              'JOSEO no mostrará como cercano un precio publicado en otra zona.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoseoAllPriceCard extends StatelessWidget {
  final JoseoAllPrice item;
  final VoidCallback onTap;

  const _JoseoAllPriceCard({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final confidenceColor = item.incorrectCount > item.confirmedCount
        ? joseoRed
        : item.confirmedCount >= 2
            ? joseoGreen
            : joseoGold;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: joseoCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: item.isBestNearby
                ? joseoGreen.withValues(alpha: .85)
                : item.isOfficial
                ? joseoGold.withValues(alpha: .42)
                : item.verifiedPlace
                    ? joseoPurple.withValues(alpha: .20)
                    : joseoGold.withValues(alpha: .30),
            width: item.isBestNearby ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            if (item.isBestNearby) ...[
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: joseoGreen.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.emoji_events_rounded,
                      color: joseoGreen,
                      size: 17,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'MEJOR PRECIO CERCA DE TI',
                      style: TextStyle(
                        color: joseoGreen,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: (item.isOfficial ? joseoGold : joseoPurple)
                        .withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    item.isOfficial
                        ? Icons.verified_rounded
                        : Icons.shopping_basket_outlined,
                    color: item.isOfficial ? joseoGold : joseoGreen,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.product,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${item.placeLabel} • ${item.distanceKm.toStringAsFixed(1)} km',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 10.5,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Text(
                            'RD\$ ${item.price.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: joseoGreen,
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          if (item.regularPrice != null &&
                              item.regularPrice! > item.price) ...[
                            const SizedBox(width: 8),
                            Text(
                              'RD\$ ${item.regularPrice!.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                                decoration: TextDecoration.lineThrough,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _miniTag(
                      item.sourceLabel,
                      item.isOfficial ? joseoGold : joseoPurple2,
                    ),
                    if (item.isOffer) ...[
                      const SizedBox(height: 5),
                      _miniTag('OFERTA', joseoRed),
                    ],
                    const SizedBox(height: 5),
                    _miniTag(
                      item.verifiedPlace
                          ? 'LUGAR VERIFICADO'
                          : 'LUGAR PENDIENTE',
                      item.verifiedPlace ? joseoGreen : joseoGold,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 11),
            const Divider(color: Colors.white10, height: 1),
            const SizedBox(height: 9),
            if (item.isOfficial)
              Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: joseoGold,
                  ),
                  const SizedBox(width: 5),
                  const Expanded(
                    child: Text(
                      'Fuente oficial/importada • No genera XP ni afecta el Radar',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 9.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    item.dateLabel,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 9,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(
                    Icons.chevron_right,
                    color: Colors.white38,
                    size: 18,
                  ),
                ],
              )
            else
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 15,
                    color: confidenceColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${item.confirmedCount} confirman',
                    style: TextStyle(
                      color: confidenceColor,
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Icon(
                    Icons.flag_outlined,
                    size: 14,
                    color: Colors.white38,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${item.incorrectCount} reportan',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 9.5,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    item.dateLabel,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 9,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(
                    Icons.chevron_right,
                    color: Colors.white38,
                    size: 18,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _miniTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: .38)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 7.3,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class JoseoOfficialPriceDetailPage extends StatelessWidget {
  final JoseoAllPrice price;

  const JoseoOfficialPriceDetailPage({
    super.key,
    required this.price,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: joseoBg,
      appBar: AppBar(
        backgroundColor: joseoBg,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Precio oficial',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF2A1B08),
                  Color(0xFF16102F),
                ],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: joseoGold.withValues(alpha: .45),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: joseoGold.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: joseoGold),
                      ),
                      child: const Text(
                        'OFICIAL',
                        style: TextStyle(
                          color: joseoGold,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (price.isOffer)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: joseoRed.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: joseoRed),
                        ),
                        child: const Text(
                          'OFERTA',
                          style: TextStyle(
                            color: joseoRed,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  price.product,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  price.placeLabel,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'RD\$ ${price.price.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: joseoGreen,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (price.regularPrice != null &&
                        price.regularPrice! > price.price) ...[
                      const SizedBox(width: 12),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(
                          'RD\$ ${price.regularPrice!.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: joseoCard,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.shield_outlined, color: joseoGold),
                    SizedBox(width: 8),
                    Text(
                      'Fuente del precio',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _detailRow(
                  'Tipo',
                  price.sourceQuality.trim().isEmpty
                      ? 'Fuente oficial/importada'
                      : 'Fuente oficial/importada • ${price.sourceQuality}',
                ),
                _detailRow('Fecha / período', price.dateLabel),
                if (price.note.trim().isNotEmpty)
                  _detailRow('Nota', price.note.trim()),
                if (price.sourceUrl.trim().isNotEmpty)
                  _detailRow('Fuente web', price.sourceUrl.trim()),
                if (price.sourceDocument.trim().isNotEmpty)
                  _detailRow('Documento', price.sourceDocument.trim()),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: joseoGreen.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: joseoGreen.withValues(alpha: .30),
              ),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: joseoGreen),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Este precio proviene de una fuente externa/oficial. '
                    'No puede recibir confirmaciones, no genera XP y no participa '
                    'en el Radar JOSEO. Confirma el precio final y la disponibilidad '
                    'directamente con el establecimiento.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class JoseoPriceDetailPage extends StatefulWidget {
  final JoseoCommunityPrice price;

  const JoseoPriceDetailPage({
    super.key,
    required this.price,
  });

  @override
  State<JoseoPriceDetailPage> createState() => _JoseoPriceDetailPageState();
}

class _JoseoPriceDetailPageState extends State<JoseoPriceDetailPage> {
  bool _working = false;
  bool _changed = false;
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    _loadPhoto();
  }

  Future<void> _loadPhoto() async {
    final url = await JoseoDataService.signedPricePhoto(widget.price.photoPath);
    if (!mounted) return;
    setState(() => _photoUrl = url);
  }

  Future<bool> _ensureAuthenticated() async {
    if (Supabase.instance.client.auth.currentUser != null) return true;

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const JoseoAuthPage()),
    );

    if (!mounted) return false;
    if (result == true) {
      await _loadPhoto();
    }

    return Supabase.instance.client.auth.currentUser != null;
  }

  Future<void> _vote(String value) async {
    final canVote = await _ensureAuthenticated();
    if (!canVote || !mounted) return;

    final user = Supabase.instance.client.auth.currentUser!;
    if (user.id == widget.price.userId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No puedes confirmar tu propio precio.'),
        ),
      );
      return;
    }

    setState(() => _working = true);

    try {
      await JoseoDataService.votePrice(
        priceId: widget.price.priceId,
        confirmation: value,
      );

      _changed = true;
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value == 'confirmed'
                ? '✅ Gracias. Confirmaste este precio.'
                : '🚩 Gracias. Marcaste este precio como incorrecto.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No pudimos guardar tu validación.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }


  Future<void> _reportPublication() async {
    final canReport = await _ensureAuthenticated();
    if (!canReport || !mounted) return;

    final user = Supabase.instance.client.auth.currentUser!;
    if (user.id == widget.price.userId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No puedes reportar tu propia publicación.'),
        ),
      );
      return;
    }

    const reasons = <String, String>{
      'wrong_price': 'Precio falso o incorrecto',
      'inappropriate_photo': 'Foto inapropiada',
      'spam': 'Spam o publicidad no autorizada',
      'nonexistent_business': 'Negocio o sucursal inexistente',
      'misleading_information': 'Información engañosa',
      'other': 'Otro motivo',
    };

    String selectedReason = 'wrong_price';
    final detailsController = TextEditingController();

    final shouldSend = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: joseoCard,
              title: const Text(
                'Reportar publicación',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Selecciona el motivo. Los reportes se revisan desde el Gestor JOSEO.',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedReason,
                      dropdownColor: joseoCard2,
                      decoration: const InputDecoration(
                        labelText: 'Motivo',
                        border: OutlineInputBorder(),
                      ),
                      items: reasons.entries
                          .map(
                            (entry) => DropdownMenuItem<String>(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() => selectedReason = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: detailsController,
                      maxLines: 3,
                      maxLength: 300,
                      decoration: const InputDecoration(
                        labelText: 'Detalles opcionales',
                        hintText: 'Explica brevemente qué encontraste.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: joseoRed,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.flag_outlined),
                  label: const Text('Enviar reporte'),
                ),
              ],
            );
          },
        );
      },
    );

    if (shouldSend != true || !mounted) {
      detailsController.dispose();
      return;
    }

    setState(() => _working = true);
    try {
      await JoseoDataService.reportPrice(
        priceId: widget.price.priceId,
        reason: selectedReason,
        details: detailsController.text.trim(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🚩 Reporte enviado. Gracias por ayudar a cuidar JOSEO.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No pudimos enviar el reporte. Inténtalo nuevamente.'),
        ),
      );
    } finally {
      detailsController.dispose();
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.price;
    final currentUser = Supabase.instance.client.auth.currentUser;
    final ownPrice = currentUser?.id == item.userId;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {},
      child: Scaffold(
        backgroundColor: joseoBg,
        appBar: AppBar(
          backgroundColor: joseoBg,
          surfaceTintColor: Colors.transparent,
          title: const Text(
            'Validar precio',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          leading: IconButton(
            onPressed: () => Navigator.pop(context, _changed),
            icon: const Icon(Icons.arrow_back_ios_new),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
          children: [
            Container(
              height: 220,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: joseoCard,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: joseoPurple.withValues(alpha: .3)),
              ),
              child: _photoUrl == null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.receipt_long_outlined,
                          size: 60,
                          color: Colors.white30,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          item.photoPath == null
                              ? 'Este reporte no tiene foto.'
                              : currentUser == null
                                  ? 'Inicia sesión para ver la evidencia.'
                                  : 'No pudimos cargar la evidencia.',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    )
                  : Image.network(
                      _photoUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white30,
                          size: 50,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            Text(
              item.product,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              item.placeLabel,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'RD\$ ${item.price.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: joseoGreen,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: (item.verifiedPlace ? joseoGreen : joseoGold)
                        .withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: item.verifiedPlace ? joseoGreen : joseoGold,
                    ),
                  ),
                  child: Text(
                    item.verifiedPlace ? 'LUGAR VERIFICADO' : 'LUGAR PENDIENTE',
                    style: TextStyle(
                      color: item.verifiedPlace ? joseoGreen : joseoGold,
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            if (item.description.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                item.description,
                style: const TextStyle(color: Colors.white70, height: 1.35),
              ),
            ],
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: joseoCard,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(Icons.people_alt_outlined, color: joseoGold),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${item.confirmedCount} confirmaciones • '
                      '${item.incorrectCount} reportes de error • '
                      '${JoseoDataService.relativeDate(item.observedAt)}',
                      style: const TextStyle(color: Colors.white60, fontSize: 10.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (ownPrice)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: joseoPurple.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.person_outline, color: joseoGreen),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Esta es tu publicación. Otros usuarios deben validarla.',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _working ? null : () => _vote('confirmed'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: joseoGreen,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text(
                        'Precio correcto',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _working ? null : () => _vote('incorrect'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: joseoRed,
                        side: const BorderSide(color: joseoRed),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text(
                        'Incorrecto',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 10),
            const Text(
              'Las validaciones ayudan al Radar JOSEO y a premiar aportes confiables. '
              'No confirmes un precio que no hayas podido verificar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 9.5, height: 1.35),
            ),
            if (!ownPrice) ...[
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: _working ? null : _reportPublication,
                icon: const Icon(Icons.report_gmailerrorred_outlined, size: 18),
                label: const Text(
                  'Reportar publicación',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: joseoRed,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================
// SUBIR PRECIO
// ============================================================
class JoseoBranchOption {
  final int id;
  final int storeId;
  final String storeName;
  final String branchName;
  final String address;
  final String city;
  final String province;
  final double? latitude;
  final double? longitude;
  final bool active;
  final String verificationStatus;
  final double? distanceMeters;

  const JoseoBranchOption({
    required this.id,
    required this.storeId,
    required this.storeName,
    required this.branchName,
    required this.address,
    required this.city,
    required this.province,
    required this.latitude,
    required this.longitude,
    required this.active,
    required this.verificationStatus,
    required this.distanceMeters,
  });

  bool get isVerified =>
      active && verificationStatus == 'verified';

  bool get isPending => verificationStatus == 'pending';

  String get displayName {
    if (branchName.toLowerCase() == storeName.toLowerCase()) {
      return storeName;
    }
    return '$storeName • $branchName';
  }

  String get locationDetail {
    final parts = <String>[
      if (address.trim().isNotEmpty) address.trim(),
      if (city.trim().isNotEmpty) city.trim(),
      if (province.trim().isNotEmpty) province.trim(),
    ];

    return parts.isEmpty ? 'Ubicación registrada' : parts.join(' • ');
  }

  JoseoBranchOption copyWithDistance(double? value) {
    return JoseoBranchOption(
      id: id,
      storeId: storeId,
      storeName: storeName,
      branchName: branchName,
      address: address,
      city: city,
      province: province,
      latitude: latitude,
      longitude: longitude,
      active: active,
      verificationStatus: verificationStatus,
      distanceMeters: value,
    );
  }
}

class PendingPriceReport {
  final String id;
  final String userId;
  final int? productId;
  final String product;
  final String price;
  final String description;
  final String? photoPath;
  final bool isOffer;

  final bool useGpsLocation;
  final int? branchId;
  final String? storeName;

  final double? latitude;
  final double? longitude;
  final double? accuracy;

  final DateTime createdAt;
  final DateTime? locationCapturedAt;

  final String status;

  PendingPriceReport({
    required this.id,
    required this.userId,
    required this.productId,
    required this.product,
    required this.price,
    required this.description,
    required this.photoPath,
    required this.isOffer,
    required this.useGpsLocation,
    required this.branchId,
    required this.storeName,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.createdAt,
    required this.locationCapturedAt,
    this.status = 'pending',
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'productId': productId,
      'product': product,
      'price': price,
      'description': description,
      'photoPath': photoPath,
      'isOffer': isOffer,
      'useGpsLocation': useGpsLocation,
      'branchId': branchId,
      'storeName': storeName,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'createdAt': createdAt.toIso8601String(),
      'locationCapturedAt':
          locationCapturedAt?.toIso8601String(),
      'status': status,
    };
  }

  factory PendingPriceReport.fromJson(
    Map<String, dynamic> json,
  ) {
    return PendingPriceReport(
      id: json['id'] as String,
      userId: json['userId'] as String? ?? '',
      productId: json['productId'] as int?,
      product: json['product'] as String,
      price: json['price'] as String,
      description: json['description'] as String? ?? '',
      photoPath: json['photoPath'] as String?,
      isOffer: json['isOffer'] as bool? ?? false,
      useGpsLocation:
          json['useGpsLocation'] as bool? ?? true,
      branchId: json['branchId'] as int?,
      storeName: json['storeName'] as String?,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      locationCapturedAt:
          json['locationCapturedAt'] != null
              ? DateTime.parse(
                  json['locationCapturedAt'] as String,
                )
              : null,
      status: json['status'] as String? ?? 'pending',
    );
  }
}

 
class JoseoProductOption {
  final int id;
  final String name;

  const JoseoProductOption({
    required this.id,
    required this.name,
  });

  factory JoseoProductOption.fromMap(Map<String, dynamic> row) {
    return JoseoProductOption(
      id: (row['id'] as num).toInt(),
      name: row['name']?.toString() ?? 'Producto',
    );
  }
}

class AddPricePage extends StatefulWidget {
  const AddPricePage({super.key});

  @override
  State<AddPricePage> createState() => _AddPricePageState();
}

class _AddPricePageState extends State<AddPricePage> {
  final ImagePicker _imagePicker = ImagePicker();
  XFile? selectedImage;

  Position? currentPosition;
  bool isGettingLocation = false;
  String locationStatus = 'Ubicación no detectada';

  int step = 0;
  int? selectedProductId;
  bool isOffer = true;
  bool useGpsLocation = true;

  DateTime? locationCapturedAt;

  final TextEditingController productSearchController =
      TextEditingController();
  final TextEditingController placeSearchController =
      TextEditingController();

  List<JoseoProductOption> productOptions = <JoseoProductOption>[];
  bool isLoadingProducts = true;
  String? productsError;

  List<JoseoBranchOption> placeOptions = <JoseoBranchOption>[];
  bool isLoadingPlaces = true;
  bool isCreatingPlace = false;
  String? placesError;
  int? selectedBranchId;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadProducts();
      await _loadPlaces();
      await _getCurrentLocation();
    });
  }


  JoseoProductOption? get selectedProductOption {
    final productId = selectedProductId;
    if (productId == null) return null;

    for (final product in productOptions) {
      if (product.id == productId) return product;
    }
    return null;
  }

  List<JoseoProductOption> get filteredProducts {
    final query = productSearchController.text.trim().toLowerCase();
    if (query.isEmpty) return productOptions;

    return productOptions
        .where((product) => product.name.toLowerCase().contains(query))
        .toList();
  }

  Future<void> _loadProducts() async {
    if (mounted) {
      setState(() {
        isLoadingProducts = true;
        productsError = null;
      });
    }

    try {
      final rows = await Supabase.instance.client
          .from('products')
          .select('id, name')
          .eq('active', true)
          .order('name');

      final loaded = rows
          .map(
            (row) => JoseoProductOption.fromMap(
              Map<String, dynamic>.from(row),
            ),
          )
          .toList();

      if (!mounted) return;

      setState(() {
        productOptions = loaded;
        isLoadingProducts = false;

        if (loaded.isNotEmpty &&
            (selectedProductId == null ||
                !loaded.any((item) => item.id == selectedProductId))) {
          selectedProductId = loaded.first.id;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        isLoadingProducts = false;
        productsError = 'No pudimos cargar los productos.';
      });
    }
  }

  JoseoBranchOption? get selectedPlace {
    final branchId = selectedBranchId;
    if (branchId == null) return null;

    for (final place in placeOptions) {
      if (place.id == branchId) return place;
    }

    return null;
  }

  List<JoseoBranchOption> get filteredPlaces {
    final query = placeSearchController.text.trim().toLowerCase();
    if (query.isEmpty) return placeOptions;

    return placeOptions.where((place) {
      return place.storeName.toLowerCase().contains(query) ||
          place.branchName.toLowerCase().contains(query) ||
          place.address.toLowerCase().contains(query) ||
          place.city.toLowerCase().contains(query) ||
          place.province.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _loadPlaces({int? preferredBranchId}) async {
    if (mounted) {
      setState(() {
        isLoadingPlaces = true;
        placesError = null;
      });
    }

    try {
      final client = Supabase.instance.client;
      final currentUserId = client.auth.currentUser?.id;

      final storeRows = await client
          .from('stores')
          .select('id, name, active, verification_status, created_by');

      final branchRows = await client.from('branches').select(
            'id, store_id, name, address, city, province, latitude, '
            'longitude, active, verification_status, created_by',
          );

      final storeNames = <int, String>{};
      final visibleStoreIds = <int>{};
      for (final row in storeRows) {
        final id = (row['id'] as num).toInt();
        final verified = row['active'] == true &&
            row['verification_status']?.toString() == 'verified';
        final createdByCurrentUser = currentUserId != null &&
            row['created_by']?.toString() == currentUserId;

        if (!verified && !createdByCurrentUser) continue;

        visibleStoreIds.add(id);
        storeNames[id] = row['name'] as String? ?? 'Negocio';
      }

      final options = <JoseoBranchOption>[];

      for (final row in branchRows) {
        final storeId = (row['store_id'] as num?)?.toInt();
        if (storeId == null || !visibleStoreIds.contains(storeId)) continue;

        final verified = row['active'] == true &&
            row['verification_status']?.toString() == 'verified';
        final createdByCurrentUser = currentUserId != null &&
            row['created_by']?.toString() == currentUserId;

        if (!verified && !createdByCurrentUser) continue;

        final latitude = (row['latitude'] as num?)?.toDouble();
        final longitude = (row['longitude'] as num?)?.toDouble();

        double? distance;
        final position = currentPosition;
        if (position != null && latitude != null && longitude != null) {
          distance = Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            latitude,
            longitude,
          );
        }

        options.add(
          JoseoBranchOption(
            id: (row['id'] as num).toInt(),
            storeId: storeId,
            storeName: storeNames[storeId] ?? 'Negocio',
            branchName: row['name'] as String? ?? 'Sucursal',
            address: row['address'] as String? ?? '',
            city: row['city'] as String? ?? '',
            province: row['province'] as String? ?? '',
            latitude: latitude,
            longitude: longitude,
            active: row['active'] == true,
            verificationStatus:
                row['verification_status'] as String? ?? 'verified',
            distanceMeters: distance,
          ),
        );
      }

      options.sort(_comparePlaces);

      int? nextSelected = preferredBranchId ?? selectedBranchId;
      bool nextGps = useGpsLocation;

      final selectedStillExists =
          options.any((place) => place.id == nextSelected);

      if (!selectedStillExists) {
        nextSelected = null;
      }

      if (nextSelected == null && currentPosition != null) {
        final nearest = _nearestVerifiedPlace(options);
        if (nearest != null &&
            nearest.distanceMeters != null &&
            nearest.distanceMeters! <= 1500) {
          nextSelected = nearest.id;
          nextGps = true;
        }
      }

      if (!mounted) return;

      setState(() {
        placeOptions = options;
        selectedBranchId = nextSelected;
        useGpsLocation = nextGps;
        isLoadingPlaces = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isLoadingPlaces = false;
        placesError = 'No pudimos cargar los negocios de JOSEO.';
      });
    }
  }

  int _comparePlaces(JoseoBranchOption a, JoseoBranchOption b) {
    if (a.isVerified != b.isVerified) {
      return a.isVerified ? -1 : 1;
    }

    final aDistance = a.distanceMeters;
    final bDistance = b.distanceMeters;

    if (aDistance != null && bDistance != null) {
      final distanceCompare = aDistance.compareTo(bDistance);
      if (distanceCompare != 0) return distanceCompare;
    } else if (aDistance != null) {
      return -1;
    } else if (bDistance != null) {
      return 1;
    }

    final storeCompare =
        a.storeName.toLowerCase().compareTo(b.storeName.toLowerCase());
    if (storeCompare != 0) return storeCompare;

    return a.branchName
        .toLowerCase()
        .compareTo(b.branchName.toLowerCase());
  }

  JoseoBranchOption? _nearestVerifiedPlace(
    List<JoseoBranchOption> options,
  ) {
    JoseoBranchOption? nearest;

    for (final place in options) {
      if (!place.isVerified || place.distanceMeters == null) continue;

      if (nearest == null ||
          place.distanceMeters! < nearest.distanceMeters!) {
        nearest = place;
      }
    }

    return nearest;
  }

  void _recalculatePlaceDistances({bool autoSelect = false}) {
    final position = currentPosition;
    if (position == null || placeOptions.isEmpty || !mounted) return;

    final updated = placeOptions.map((place) {
      if (place.latitude == null || place.longitude == null) {
        return place.copyWithDistance(null);
      }

      return place.copyWithDistance(
        Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          place.latitude!,
          place.longitude!,
        ),
      );
    }).toList()
      ..sort(_comparePlaces);

    var nextSelected = selectedBranchId;
    var nextGps = useGpsLocation;

    if (autoSelect && nextSelected == null) {
      final nearest = _nearestVerifiedPlace(updated);
      if (nearest != null &&
          nearest.distanceMeters != null &&
          nearest.distanceMeters! <= 1500) {
        nextSelected = nearest.id;
        nextGps = true;
      }
    }

    setState(() {
      placeOptions = updated;
      selectedBranchId = nextSelected;
      useGpsLocation = nextGps;
    });
  }

  Future<void> _getCurrentLocation() async {
    if (!mounted) return;

    setState(() {
      isGettingLocation = true;
      locationStatus = 'Buscando tu ubicación...';
    });

    try {
      final serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        if (!mounted) return;

        setState(() {
          isGettingLocation = false;
          locationStatus = 'Activa la ubicación del teléfono';
        });
        return;
      }

      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        if (!mounted) return;

        setState(() {
          isGettingLocation = false;
          locationStatus = 'Permiso de ubicación rechazado';
        });
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        if (!mounted) return;

        setState(() {
          isGettingLocation = false;
          locationStatus =
              'Permiso bloqueado. Actívalo en Ajustes.';
        });
        return;
      }

      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      );

      final position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );

      if (!mounted) return;

      setState(() {
        currentPosition = position;
        locationCapturedAt = DateTime.now();
        isGettingLocation = false;
        locationStatus =
            'Ubicación guardada • precisión ${position.accuracy.toStringAsFixed(0)} m';
      });

      _recalculatePlaceDistances(autoSelect: true);
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isGettingLocation = false;
        locationStatus = 'No pudimos obtener la ubicación';
      });
    }
  }

  Future<void> _selectNearestPlaceFromGps() async {
    if (currentPosition == null) {
      await _getCurrentLocation();
    }

    if (!mounted || currentPosition == null) return;

    if (placeOptions.isEmpty) {
      await _loadPlaces();
    } else {
      _recalculatePlaceDistances();
    }

    if (!mounted) return;

    final nearest = _nearestVerifiedPlace(placeOptions);

    if (nearest == null ||
        nearest.distanceMeters == null ||
        nearest.distanceMeters! > 1500) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '📍 No encontramos un negocio verificado suficientemente cerca. Búscalo en la lista o agrégalo a JOSEO.',
          ),
        ),
      );
      return;
    }

    setState(() {
      selectedBranchId = nearest.id;
      useGpsLocation = true;
    });
  }

  String _distanceLabel(JoseoBranchOption place) {
    if (place.isPending) {
      return 'Pendiente de validación';
    }

    final distance = place.distanceMeters;
    if (distance == null) {
      return place.locationDetail;
    }

    if (distance < 1000) {
      return '${distance.round()} m de ti';
    }

    return '${(distance / 1000).toStringAsFixed(1)} km de ti';
  }

  Color _placeColor(JoseoBranchOption place) {
    const colors = <Color>[
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.redAccent,
      Colors.teal,
      Colors.amber,
      Colors.indigo,
      Colors.cyan,
      Colors.deepOrange,
    ];

    return colors[place.storeId.abs() % colors.length];
  }

  String _friendlyPlaceError(Object error) {
    final value = error.toString();

    if (value.contains('PLACE_DAILY_LIMIT')) {
      return 'Llegaste al límite de 5 lugares pendientes por hoy.';
    }
    if (value.contains('GPS_REQUIRED_FOR_NEW_PLACE')) {
      return 'JOSEO necesita tu ubicación GPS para crear un lugar nuevo.';
    }
    if (value.contains('STORE_NAME_REQUIRED')) {
      return 'Escribe el nombre del negocio.';
    }
    if (value.contains('AUTH_REQUIRED')) {
      return 'Debes iniciar sesión para agregar un negocio.';
    }
    if (value.contains('STORE_REJECTED') ||
        value.contains('BRANCH_REJECTED')) {
      return 'Ese lugar fue rechazado anteriormente. Revisa el nombre o la ubicación.';
    }

    return 'No pudimos agregar el lugar. Revisa los datos e inténtalo otra vez.';
  }

  Future<void> _showCreatePlaceDialog() async {
    if (isCreatingPlace) return;

    if (currentPosition == null) {
      await _getCurrentLocation();
    }

    if (!mounted) return;

    if (currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Activa la ubicación para agregar un negocio nuevo a JOSEO.',
          ),
        ),
      );
      return;
    }

    final storeController = TextEditingController();
    final branchController = TextEditingController();
    final addressController = TextEditingController();
    final cityController = TextEditingController();
    final provinceController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    Map<String, dynamic>? created;

    try {
      created = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          var saving = false;
          String? dialogError;

          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> savePlace() async {
                if (saving || !formKey.currentState!.validate()) return;

                setDialogState(() {
                  saving = true;
                  dialogError = null;
                });

                try {
                  final position = currentPosition!;

                  final response = await Supabase.instance.client.rpc(
                    'joseo_create_or_find_place',
                    params: {
                      'p_store_name': storeController.text.trim(),
                      'p_branch_name': branchController.text.trim().isEmpty
                          ? null
                          : branchController.text.trim(),
                      'p_address': addressController.text.trim().isEmpty
                          ? null
                          : addressController.text.trim(),
                      'p_city': cityController.text.trim().isEmpty
                          ? null
                          : cityController.text.trim(),
                      'p_province': provinceController.text.trim().isEmpty
                          ? null
                          : provinceController.text.trim(),
                      'p_latitude': position.latitude,
                      'p_longitude': position.longitude,
                    },
                  );

                  Map<String, dynamic>? row;

                  if (response is List && response.isNotEmpty) {
                    row = Map<String, dynamic>.from(
                      response.first as Map,
                    );
                  } else if (response is Map) {
                    row = Map<String, dynamic>.from(response);
                  }

                  if (row == null) {
                    throw StateError('EMPTY_PLACE_RESPONSE');
                  }

                  if (!dialogContext.mounted) return;
                  Navigator.pop(dialogContext, row);
                } catch (error) {
                  if (!dialogContext.mounted) return;

                  setDialogState(() {
                    saving = false;
                    dialogError = _friendlyPlaceError(error);
                  });
                }
              }

              return AlertDialog(
                backgroundColor: joseoCard,
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 24,
                ),
                title: const Row(
                  children: [
                    Icon(Icons.add_business_rounded, color: joseoGreen),
                    SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'Agregar negocio a JOSEO',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: 440,
                  child: SingleChildScrollView(
                    child: Form(
                      key: formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'JOSEO usará tu ubicación actual como evidencia. Si el negocio ya existe, reutilizaremos el registro para evitar duplicados.',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 10.5,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: storeController,
                            textCapitalization: TextCapitalization.words,
                            decoration: _placeInputDecoration(
                              'Nombre del negocio *',
                              'Ej: Jumbo, Farmacia Carol, Colmado Don José',
                              Icons.storefront_rounded,
                            ),
                            validator: (value) {
                              if (value == null || value.trim().length < 2) {
                                return 'Escribe el nombre del negocio.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: branchController,
                            textCapitalization: TextCapitalization.words,
                            decoration: _placeInputDecoration(
                              'Sucursal o local',
                              'Ej: Downtown, Friusa, Av. España',
                              Icons.location_city_rounded,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: addressController,
                            textCapitalization: TextCapitalization.words,
                            decoration: _placeInputDecoration(
                              'Dirección',
                              'Calle, plaza o referencia',
                              Icons.pin_drop_outlined,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: cityController,
                                  textCapitalization:
                                      TextCapitalization.words,
                                  decoration: _placeInputDecoration(
                                    'Ciudad / sector',
                                    'Ej: Bávaro',
                                    Icons.location_on_outlined,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextFormField(
                                  controller: provinceController,
                                  textCapitalization:
                                      TextCapitalization.words,
                                  decoration: _placeInputDecoration(
                                    'Provincia',
                                    'Ej: La Altagracia',
                                    Icons.map_outlined,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: joseoGreen.withValues(alpha: .08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: joseoGreen.withValues(alpha: .25),
                              ),
                            ),
                            child: Text(
                              '📍 GPS: ${currentPosition!.latitude.toStringAsFixed(6)}, '
                              '${currentPosition!.longitude.toStringAsFixed(6)}',
                              style: const TextStyle(
                                color: joseoGreen,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (dialogError != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              dialogError!,
                              style: const TextStyle(
                                color: joseoRed,
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          const Text(
                            'Un lugar nuevo queda pendiente de validación. Puedes publicar el precio allí, pero no modifica el Radar JOSEO hasta ser verificado.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 9.5,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: saving
                        ? null
                        : () => Navigator.pop(dialogContext),
                    child: const Text('Cancelar'),
                  ),
                  ElevatedButton.icon(
                    onPressed: saving ? null : savePlace,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: joseoGreen,
                      foregroundColor: Colors.black,
                    ),
                    icon: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.add_business_rounded),
                    label: Text(
                      saving ? 'Guardando...' : 'Agregar lugar',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      // showDialog completa su Future en cuanto Navigator.pop() es llamado,
      // pero el árbol del diálogo puede seguir desmontándose durante ese frame.
      // Diferimos la liberación de los controladores hasta el siguiente frame
      // para evitar la aserción de Flutter `_dependents.isEmpty` al cancelar.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        storeController.dispose();
        branchController.dispose();
        addressController.dispose();
        cityController.dispose();
        provinceController.dispose();
      });
    }

    if (!mounted || created == null) return;

    final branchId = (created['branch_id'] as num?)?.toInt();
    if (branchId == null) return;

    setState(() {
      isCreatingPlace = true;
    });

    await _loadPlaces(preferredBranchId: branchId);

    if (!mounted) return;

    setState(() {
      selectedBranchId = branchId;
      useGpsLocation = true;
      isCreatingPlace = false;
    });

    final createdNew = created['created_new'] == true;
    final status = created['verification_status'] as String? ?? 'pending';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          createdNew && status == 'pending'
              ? '✅ Lugar agregado. Quedó pendiente de validación y ya puedes publicar tu precio allí.'
              : '✅ Encontramos ese lugar en JOSEO y quedó seleccionado.',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  InputDecoration _placeInputDecoration(
    String label,
    String hint,
    IconData icon,
  ) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white30, fontSize: 10),
      prefixIcon: Icon(icon, color: joseoGreen, size: 20),
      filled: true,
      fillColor: joseoBg2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: BorderSide(
          color: joseoPurple.withValues(alpha: .25),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: joseoGreen),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
  final XFile? image = await _imagePicker.pickImage(
    source: source,
    imageQuality: 85,
  );

  if (image == null) return;

  if (!mounted) return;

  setState(() {
    selectedImage = image;
  });
}

void _showImageSourcePicker() {
  showModalBottomSheet(
    context: context,
    backgroundColor: joseoCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(24),
      ),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Agregar foto',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 16),

              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: joseoGreen,
                  child: Icon(
                    Icons.camera_alt,
                    color: Colors.black,
                  ),
                ),
                title: const Text('Tomar foto'),
                subtitle: const Text(
                  'Usar la cámara del teléfono',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),

              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: joseoPurple,
                  child: Icon(
                    Icons.photo_library,
                    color: Colors.white,
                  ),
                ),
                title: const Text('Elegir de galería'),
                subtitle: const Text(
                  'Seleccionar una foto existente',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

  final TextEditingController priceController =
      TextEditingController(text: '184.95');
final TextEditingController descriptionController =
    TextEditingController();

  final List<String> steps = const [
    'Producto',
    'Precio',
    'Lugar',
    'Foto',
  ];

  @override
  void dispose() {
    priceController.dispose();
    descriptionController.dispose();
    productSearchController.dispose();
    placeSearchController.dispose();
    super.dispose();
  }

Future<PendingPriceReport> _savePendingReport() async {
  final user = Supabase.instance.client.auth.currentUser;

  if (user == null) {
    throw StateError('Debes iniciar sesión para publicar.');
  }

  final createdAt = DateTime.now();
  final id = 'price_${createdAt.microsecondsSinceEpoch}';

  String? savedPhotoPath;

  // Conservamos la evidencia en almacenamiento permanente hasta que
  // Supabase confirme que el precio y la foto fueron recibidos.
  if (selectedImage != null) {
    final appDirectory = await getApplicationDocumentsDirectory();
    final photoDirectory = Directory(
      '${appDirectory.path}/pending_price_photos',
    );

    if (!await photoDirectory.exists()) {
      await photoDirectory.create(recursive: true);
    }

    final originalFile = File(selectedImage!.path);
    var extension = '.jpg';
    final lowerPath = selectedImage!.path.toLowerCase();

    if (lowerPath.endsWith('.png')) {
      extension = '.png';
    } else if (lowerPath.endsWith('.jpeg')) {
      extension = '.jpeg';
    } else if (lowerPath.endsWith('.webp')) {
      extension = '.webp';
    }

    final savedFile = await originalFile.copy(
      '${photoDirectory.path}/$id$extension',
    );

    savedPhotoPath = savedFile.path;
  }

  final place = selectedPlace;

  if (place == null) {
    throw StateError('Selecciona el negocio donde viste este precio.');
  }

  final selectedProduct = selectedProductOption;
  if (selectedProduct == null) {
    throw StateError('Selecciona un producto antes de publicar.');
  }

  final report = PendingPriceReport(
    id: id,
    userId: user.id,
    productId: selectedProduct.id,
    product: selectedProduct.name,
    price: priceController.text.trim(),
    description: descriptionController.text.trim(),
    photoPath: savedPhotoPath,
    isOffer: isOffer,
    useGpsLocation: useGpsLocation,
    branchId: place.id,
    storeName: place.displayName,
    latitude: currentPosition?.latitude,
    longitude: currentPosition?.longitude,
    accuracy: currentPosition?.accuracy,
    createdAt: createdAt,
    locationCapturedAt: locationCapturedAt,
    status: 'pending',
  );

  final preferences = await SharedPreferences.getInstance();
  final pendingReports =
      preferences.getStringList('pending_price_reports') ?? <String>[];

  pendingReports.add(jsonEncode(report.toJson()));

  await preferences.setStringList(
    'pending_price_reports',
    pendingReports,
  );

  return report;
}

  Future<void> nextStep() async {
    if (step == 0 && selectedProductOption == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selecciona un producto antes de continuar.'),
        ),
      );
      return;
    }

    if (step == 1) {
      final numericPrice = double.tryParse(
        priceController.text.replaceAll(',', '.').trim(),
      );

      if (numericPrice == null || numericPrice <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Escribe un precio válido antes de continuar.'),
          ),
        );
        return;
      }
    }

    if (step == 2 && selectedBranchId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Selecciona un negocio o agrega uno nuevo antes de continuar.',
          ),
        ),
      );
      return;
    }

    if (step < 3) {
      setState(() {
        step++;
      });
      return;
    }

    if (Supabase.instance.client.auth.currentUser == null) {
      final authenticated = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => const JoseoAuthPage(),
        ),
      );

      if (!mounted ||
          authenticated != true ||
          Supabase.instance.client.auth.currentUser == null) {
        return;
      }
    }

    try {
      final report = await _savePendingReport();

      // No confiamos solamente en connectivity_plus. Intentamos la subida
      // real; si Supabase falla por cualquier motivo, el reporte permanece
      // en la cola local y se vuelve a intentar después.
      final synced =
          await JoseoSyncManager.instance.syncPendingReport(report.id);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            synced
                ? '✅ Precio publicado en JOSEO correctamente.'
                : '📴 Precio guardado en el teléfono. JOSEO lo sincronizará cuando pueda conectarse.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );

      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No pudimos guardar el precio: $error',
          ),
        ),
      );
    }
  }

  void previousStep() {
    if (step > 0) {
      setState(() {
        step--;
      });
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: joseoBg,
      appBar: AppBar(
        backgroundColor: joseoBg,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          onPressed: previousStep,
          icon: const Icon(
            Icons.arrow_back_ios_new,
            size: 20,
          ),
        ),
        title: const Text(
          'Subir precio',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
          ),
        ),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0D062A),
              joseoBg,
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            14,
            6,
            14,
            14,
          ),
          child: Column(
            children: [
              _stepIndicator(),

              const SizedBox(height: 18),

              Expanded(
                child: SingleChildScrollView(
                  child: AnimatedSwitcher(
                    duration: const Duration(
                      milliseconds: 220,
                    ),
                    child: _stepBody(),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              _bottomButton(),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================
  // INDICADOR DE PASOS
  // ==========================================================

  Widget _stepIndicator() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        8,
        12,
        8,
        10,
      ),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: joseoPurple.withValues(alpha: .25),
        ),
      ),
      child: Row(
        children: List.generate(
          4,
          (index) {
            final active = index <= step;
            final current = index == step;

            return Expanded(
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(
                      milliseconds: 180,
                    ),
                    width: current ? 38 : 32,
                    height: current ? 38 : 32,
                    decoration: BoxDecoration(
                      color: active
                          ? joseoGreen
                          : const Color(0xFF27213E),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: current
                            ? Colors.white
                            : Colors.transparent,
                        width: 2,
                      ),
                      boxShadow: current
                          ? [
                              BoxShadow(
                                color: joseoGreen
                                    .withValues(alpha: .35),
                                blurRadius: 12,
                              ),
                            ]
                          : null,
                    ),
                    child: Center(
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          color: active
                              ? Colors.black
                              : Colors.white38,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 6),

                  Text(
                    steps[index],
                    style: TextStyle(
                      color: current
                          ? joseoGreen
                          : active
                              ? Colors.white70
                              : Colors.white38,
                      fontSize: 9,
                      fontWeight: current
                          ? FontWeight.w900
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ==========================================================
  // CONTENIDO DEL PASO
  // ==========================================================

  Widget _stepBody() {
    switch (step) {
      case 0:
        return _productStep();
      case 1:
        return _priceStep();
      case 2:
        return _storeStep();
      default:
        return _photoStep();
    }
  }

  // ==========================================================
  // PASO 1 - PRODUCTO
  // ==========================================================

  Widget _productStep() {
    final visibleProducts = filteredProducts;

    return Column(
      key: const ValueKey('product'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          '1. Producto',
          '¿Qué producto encontraste?',
        ),
        const SizedBox(height: 14),
        TextField(
          controller: productSearchController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Buscar entre ${productOptions.length} productos',
            hintStyle: const TextStyle(
              color: Colors.white38,
            ),
            prefixIcon: const Padding(
              padding: EdgeInsets.all(10),
              child: SafeAsset(
                asset: JoseoAssets.buscarProducto,
                width: 26,
                height: 26,
                fallback: Icons.search,
              ),
            ),
            suffixIcon: productSearchController.text.trim().isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      productSearchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white38,
                    ),
                  ),
            filled: true,
            fillColor: joseoCard,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: joseoPurple.withValues(alpha: .20),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (isLoadingProducts)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Center(
              child: CircularProgressIndicator(color: joseoGreen),
            ),
          )
        else if (productsError != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: joseoCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: joseoRed.withValues(alpha: .30),
              ),
            ),
            child: Column(
              children: [
                Text(
                  productsError!,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _loadProducts,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
              ],
            ),
          )
        else if (visibleProducts.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: joseoCard,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              'No encontramos productos con ese nombre.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60),
            ),
          )
        else
          ...visibleProducts.map(_productCard),
      ],
    );
  }

  Widget _productCard(JoseoProductOption product) {
    final selected = selectedProductId == product.id;

    return GestureDetector(
      onTap: () {
        setState(() {
          selectedProductId = product.id;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF21184A)
              : joseoCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? joseoGreen
                : Colors.white.withValues(alpha: .04),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: joseoGreen.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.shopping_basket_outlined,
                color: joseoGreen,
                size: 31,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Producto registrado en JOSEO',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Container(
                width: 29,
                height: 29,
                decoration: const BoxDecoration(
                  color: joseoGreen,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check,
                  color: Colors.black,
                  size: 18,
                ),
              )
            else
              const Icon(
                Icons.chevron_right,
                color: Colors.white38,
              ),
          ],
        ),
      ),
    );
  }

  // ==========================================================
  // PASO 2 - PRECIO
  // ==========================================================

  Widget _priceStep() {
    return Column(
      key: const ValueKey('price'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          '2. Precio',
          'Escribe exactamente el precio que viste.',
        ),

        const SizedBox(height: 16),

        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: joseoCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color:
                  joseoPurple.withValues(alpha: .25),
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const SafeAsset(
                    asset: JoseoAssets.moneda2,
                    width: 52,
                    height: 52,
                    fallback: Icons.attach_money,
                  ),

                  const SizedBox(width: 12),

                  Expanded(
                    child: TextField(
                      controller: priceController,
                      keyboardType:
                          const TextInputType
                              .numberWithOptions(
                        decimal: true,
                      ),
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w900,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Precio encontrado',
                        prefixText: 'RD\$ ',
                        filled: true,
                        fillColor: joseoBg2,
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),
const SizedBox(height: 14),

TextField(
  controller: descriptionController,
  maxLines: 3,
  decoration: InputDecoration(
    labelText: 'Descripción',
    hintText: 'Ej: Oferta especial, paquete de 1 litro...',
    hintStyle: const TextStyle(
      color: Colors.white38,
    ),
    filled: true,
    fillColor: joseoBg2,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(
        color: joseoPurple.withValues(alpha: .25),
      ),
    ),
  ),
),

const SizedBox(height: 8),

              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: isOffer,
                activeTrackColor: joseoGreen,
                title: const Text(
                  'Este precio es una oferta',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                subtitle: const Text(
                  'JOSEO la destacará para otros usuarios.',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 9,
                  ),
                ),
                secondary: const SafeAsset(
                  asset: JoseoAssets.llamita,
                  width: 35,
                  height: 35,
                  fallback:
                      Icons.local_fire_department,
                ),
                onChanged: (value) {
                  setState(() {
                    isOffer = value;
                  });
                },
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        _infoBox(
          icon: Icons.lightbulb_outline,
          title: 'Consejo JOSEO',
          text:
              'Verifica que el precio tenga impuestos incluidos y corresponda al producto seleccionado.',
        ),
      ],
    );
  }

  // ==========================================================
  // PASO 3 - LUGAR
  // ==========================================================

  Widget _storeStep() {
    final places = filteredPlaces;
    final current = selectedPlace;

    return Column(
      key: const ValueKey('store'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          '3. Lugar',
          'Elige el negocio exacto. Si no aparece, agrégalo a JOSEO.',
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [
                Color(0xFF134A35),
                Color(0xFF0C2F30),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: currentPosition != null
                  ? joseoGreen
                  : Colors.white12,
            ),
          ),
          child: Row(
            children: [
              const SafeAsset(
                asset: JoseoAssets.pinLocalizacion,
                width: 42,
                height: 46,
                fallback: Icons.location_on,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isGettingLocation
                          ? 'Detectando tu ubicación...'
                          : locationStatus,
                      style: TextStyle(
                        color: currentPosition != null
                            ? joseoGreen
                            : Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (currentPosition != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Lat: ${currentPosition!.latitude.toStringAsFixed(6)}  '
                        'Lng: ${currentPosition!.longitude.toStringAsFixed(6)}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 9,
                        ),
                      ),
                      const SizedBox(height: 3),
                      const Text(
                        'Tu GPS se conserva como evidencia aunque elijas el negocio manualmente.',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed:
                    isGettingLocation ? null : _getCurrentLocation,
                icon: isGettingLocation
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: joseoGreen,
                        ),
                      )
                    : const Icon(
                        Icons.refresh_rounded,
                        color: joseoGreen,
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: isGettingLocation
                ? null
                : _selectNearestPlaceFromGps,
            style: OutlinedButton.styleFrom(
              foregroundColor: joseoGreen,
              side: BorderSide(
                color: useGpsLocation && current != null
                    ? joseoGreen
                    : Colors.white24,
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.my_location_rounded),
            label: Text(
              currentPosition != null
                  ? 'Detectar negocio cercano con GPS'
                  : 'Detectar mi ubicación',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
        if (current != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: current.isPending
                  ? joseoGold.withValues(alpha: .10)
                  : joseoGreen.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: current.isPending
                    ? joseoGold.withValues(alpha: .40)
                    : joseoGreen.withValues(alpha: .35),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  current.isPending
                      ? Icons.hourglass_top_rounded
                      : Icons.check_circle_rounded,
                  color: current.isPending ? joseoGold : joseoGreen,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Lugar seleccionado',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 9,
                        ),
                      ),
                      Text(
                        current.displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (useGpsLocation)
                  _placeStatusChip('GPS', joseoGreen),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: placeSearchController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Buscar supermercado, farmacia, colmado, tienda...',
            hintStyle: const TextStyle(
              color: Colors.white38,
              fontSize: 10.5,
            ),
            prefixIcon: const Icon(Icons.search, color: joseoGreen),
            suffixIcon: placeSearchController.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      placeSearchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white54,
                    ),
                  ),
            filled: true,
            fillColor: joseoCard,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),
              borderSide: BorderSide(
                color: joseoPurple.withValues(alpha: .25),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (isLoadingPlaces)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: CircularProgressIndicator(color: joseoGreen),
            ),
          )
        else if (placesError != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: joseoRed.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: joseoRed.withValues(alpha: .25),
              ),
            ),
            child: Column(
              children: [
                Text(
                  placesError!,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10.5,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _loadPlaces,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
              ],
            ),
          )
        else if (places.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: joseoCard,
              borderRadius: BorderRadius.circular(15),
            ),
            child: const Text(
              'No encontramos un negocio con esa búsqueda. Puedes agregarlo a JOSEO debajo.',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 10.5,
              ),
            ),
          )
        else
          ...places.map(_placeCard),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: isCreatingPlace ? null : _showCreatePlaceDialog,
            style: ElevatedButton.styleFrom(
              backgroundColor: joseoPurple,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            icon: isCreatingPlace
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.add_business_rounded),
            label: const Text(
              '¿No aparece? Agregar negocio a JOSEO',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _infoBox(
          icon: Icons.shield_outlined,
          title: 'Protegemos el Radar JOSEO',
          text:
              'Un lugar creado por la comunidad queda pendiente de validación. Puedes publicar allí, pero no altera el índice de precios hasta ser verificado.',
        ),
      ],
    );
  }

  Widget _placeCard(JoseoBranchOption place) {
    final selected = selectedBranchId == place.id;
    final color = _placeColor(place);

    return GestureDetector(
      onTap: () {
        setState(() {
          selectedBranchId = place.id;
          useGpsLocation = false;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF21184A)
              : joseoCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? joseoGreen
                : place.isPending
                    ? joseoGold.withValues(alpha: .28)
                    : Colors.transparent,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .20),
                shape: BoxShape.circle,
              ),
              child: Icon(
                place.isPending
                    ? Icons.add_business_rounded
                    : Icons.storefront_rounded,
                color: color,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          place.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      if (place.isPending) ...[
                        const SizedBox(width: 6),
                        _placeStatusChip('PENDIENTE', joseoGold),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _distanceLabel(place),
                    style: TextStyle(
                      color: place.isPending
                          ? joseoGold
                          : Colors.white54,
                      fontSize: 9.5,
                      fontWeight: place.isPending
                          ? FontWeight.w700
                          : FontWeight.normal,
                    ),
                  ),
                  if (place.locationDetail != 'Ubicación registrada') ...[
                    const SizedBox(height: 2),
                    Text(
                      place.locationDetail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 8.8,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 7),
            if (selected)
              const Icon(
                Icons.check_circle,
                color: joseoGreen,
                size: 28,
              )
            else
              const Icon(
                Icons.chevron_right,
                color: Colors.white38,
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeStatusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withValues(alpha: .38),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 7.5,
          fontWeight: FontWeight.w900,
          letterSpacing: .3,
        ),
      ),
    );
  }

  // ==========================================================
  // PASO 4 - FOTO
  // ==========================================================

  Widget _photoStep() {
    return Column(
      key: const ValueKey('photo'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          '4. Foto',
          'Opcional, pero ayuda a verificar la oferta.',
        ),

        const SizedBox(height: 14),

        Container(
          width: double.infinity,
          height: 245,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF211044),
                Color(0xFF071C4B),
              ],
            ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: joseoGreen,
              width: 1.5,
            ),
          ),
          child: Stack(
            children: [
 Center(
  child: selectedImage != null
      ? ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Image.file(
            File(selectedImage!.path),
            width: double.infinity,
            height: 245,
            fit: BoxFit.cover,
          ),
        )
      : const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SafeAsset(
              asset: JoseoAssets.joseParado,
              width: 105,
              height: 105,
              fallback: Icons.camera_alt,
            ),
            SizedBox(height: 8),
            Text(
              'Agrega una foto del precio',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
            SizedBox(height: 3),
            Text(
              'Etiqueta, góndola o ticket',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 10,
              ),
            ),
          ],
        ),
),
 Positioned(
  right: 14,
  bottom: 14,
  child: GestureDetector(
    onTap: _showImageSourcePicker,
    child: Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: joseoGreen,
        borderRadius: BorderRadius.circular(15),
      ),
      child: const Icon(
        Icons.camera_alt,
        color: Colors.black,
        size: 28,
      ),
    ),
  ),
),            ],
          ),
        ),

        const SizedBox(height: 14),

        _summaryCard(),

        const SizedBox(height: 14),

        _infoBox(
          icon: Icons.verified_outlined,
          title: 'Ayuda a confirmar',
          text:
              'Una foto clara hace que otros usuarios puedan validar tu precio más rápido.',
        ),
      ],
    );
  }

  // ==========================================================
  // RESUMEN
  // ==========================================================

  Widget _summaryCard() {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: joseoPurple2.withValues(alpha: .30),
        ),
      ),
      child: Column(
        children: [
          const Row(
            children: [
              Icon(
                Icons.receipt_long,
                color: joseoGold,
                size: 21,
              ),
              SizedBox(width: 8),
              Text(
                'Resumen de tu publicación',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          _summaryRow(
            'Producto',
            selectedProductOption?.name ?? 'Sin producto',
          ),

          _summaryRow(
            'Precio',
            'RD\$ ${priceController.text}',
          ),

          _summaryRow(
  'Descripción',
  descriptionController.text.trim().isEmpty
      ? 'Sin descripción'
      : descriptionController.text.trim(),
),

          _summaryRow(
            'Lugar',
            selectedPlace == null
                ? 'Lugar pendiente'
                : '${selectedPlace!.displayName}${useGpsLocation ? ' • GPS' : ''}',
          ),
          _summaryRow(
            'Oferta',
            isOffer ? 'Sí 🔥' : 'No',
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 4,
      ),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 10,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // TÍTULO
  // ==========================================================

  Widget _sectionTitle(
    String title,
    String subtitle,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 10.5,
          ),
        ),
      ],
    );
  }

  // ==========================================================
  // INFO BOX
  // ==========================================================

  Widget _infoBox({
    required IconData icon,
    required String title,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1438),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: joseoPurple.withValues(alpha: .25),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: joseoGold,
            size: 25,
          ),

          const SizedBox(width: 10),

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // BOTÓN INFERIOR
  // ==========================================================

  Widget _bottomButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: nextStep,
        style: ElevatedButton.styleFrom(
          backgroundColor: joseoGreen,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(
            vertical: 15,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 8,
          shadowColor:
              joseoGreen.withValues(alpha: .30),
        ),
        child: Text(
          step == 3
              ? 'Publicar precio  🚀'
              : 'Continuar',
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
class ProductChoice extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;

  const ProductChoice(
    this.title,
    this.subtitle,
    this.icon,
    this.color, {
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: color,
            size: 38,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right,
            color: Colors.white54,
          ),
        ],
      ),
    );
  }
}

// ============================================================
// GAMIFICACIÓN REAL
// ============================================================

class GamificationPage extends StatefulWidget {
  const GamificationPage({super.key});

  @override
  State<GamificationPage> createState() => _GamificationPageState();
}

class _GamificationPageState extends State<GamificationPage> {
  late Future<JoseoUserStats> _future;

  @override
  void initState() {
    super.initState();
    _future = JoseoDataService.loadMyStats();
  }

  void _reload() {
    setState(() {
      _future = JoseoDataService.loadMyStats();
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;

    return Scaffold(
      backgroundColor: joseoBg,
      appBar: AppBar(
        backgroundColor: joseoBg,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Niveles y premios',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          if (user != null)
            IconButton(
              onPressed: _reload,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: user == null ? _guest(context) : _authenticated(),
    );
  }

  Widget _guest(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SafeAsset(
              asset: JoseoAssets.ganaPuntos,
              width: 130,
              height: 130,
              fallback: Icons.emoji_events_outlined,
            ),
            const SizedBox(height: 12),
            const Text(
              'Inicia sesión para ver tu progreso',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () async {
                await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(builder: (_) => const JoseoAuthPage()),
                );
                if (mounted) _reload();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: joseoGreen,
                foregroundColor: Colors.black,
              ),
              child: const Text('Iniciar sesión'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _authenticated() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF13073A), joseoBg],
        ),
      ),
      child: FutureBuilder<JoseoUserStats>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: joseoGreen),
            );
          }

          final stats = snapshot.data ?? JoseoUserStats.zero;
          final currentLevel = JoseoGamification.levelForXp(stats.xp);
          final progress = JoseoGamification.progressForXp(stats.xp);

          return RefreshIndicator(
            color: joseoGreen,
            onRefresh: () async {
              _reload();
              await _future;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
              children: [
                _levelHero(currentLevel, stats.xp, progress),
                const SizedBox(height: 14),
                _statsGrid(stats),
                const SizedBox(height: 20),
                const Text(
                  'Cómo ganas XP',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 10),
                _rule(
                  Icons.verified_outlined,
                  'Precio validado',
                  '+10 XP cuando tu precio recibe al menos 2 confirmaciones y mantiene mayoría positiva.',
                ),
                _rule(
                  Icons.fact_check_outlined,
                  'Validar a otros',
                  'Tus confirmaciones mejoran el Radar y construyen tu reputación comunitaria.',
                ),
                _rule(
                  Icons.store_mall_directory_outlined,
                  'Explorar nuevas tiendas',
                  'Los reportes válidos en sucursales diferentes desbloquean insignias.',
                ),
                _rule(
                  Icons.shield_outlined,
                  'Sistema anti-trampa',
                  'Reportes rechazados, duplicados o sospechosos no generan recompensas.',
                ),
                const SizedBox(height: 20),
                const Text(
                  'Ruta de niveles',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 10),
                ...JoseoGamification.levels.map(
                  (level) => _levelCard(level, stats.xp >= level.minXp),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Insignias',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 10),
                _achievementCard(
                  JoseoGamification.achievements[0],
                  stats.firstJoseo,
                ),
                _achievementCard(
                  JoseoGamification.achievements[1],
                  stats.frequentPublisher,
                ),
                _achievementCard(
                  JoseoGamification.achievements[2],
                  stats.verifiedHunter,
                ),
                _achievementCard(
                  JoseoGamification.achievements[3],
                  stats.storeExplorer,
                ),
                _achievementCard(
                  JoseoGamification.achievements[4],
                  stats.communityHeart,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _statsGrid(JoseoUserStats stats) {
    return Row(
      children: [
        Expanded(
          child: _stat('${stats.publishedPrices}', 'Precios\npublicados'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _stat('${stats.validatedPrices}', 'Precios\nvalidados'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _stat('${stats.confirmationsMade}', 'Validaciones\nhechas'),
        ),
      ],
    );
  }

  Widget _stat(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: joseoGreen,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 8.5),
          ),
        ],
      ),
    );
  }

  Widget _levelHero(
    JoseoLevelDefinition level,
    int xp,
    double progress,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF32125B), Color(0xFF0D2751)],
        ),
        border: Border.all(color: joseoGold.withValues(alpha: .4)),
      ),
      child: Row(
        children: [
          SafeAsset(
            asset: level.asset,
            width: 74,
            height: 74,
            fallback: Icons.emoji_events_outlined,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TU NIVEL JOSEO',
                  style: TextStyle(
                    color: joseoGold,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .7,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  level.name,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  '$xp XP',
                  style: const TextStyle(
                    color: joseoGreen,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: joseoBg,
                    valueColor: const AlwaysStoppedAnimation(joseoGreen),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rule(IconData icon, String title, String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: joseoPurple.withValues(alpha: .2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: joseoGreen, size: 28),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _levelCard(JoseoLevelDefinition level, bool reached) {
    final maxText = level.maxXp >= 999999
        ? '${level.minXp}+ XP'
        : '${level.minXp} - ${level.maxXp} XP';

    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: reached
              ? joseoGreen.withValues(alpha: .5)
              : Colors.white.withValues(alpha: .06),
        ),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: reached ? 1 : .38,
            child: SafeAsset(
              asset: level.asset,
              width: 48,
              height: 48,
              fallback: Icons.lock_outline,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  level.name,
                  style: TextStyle(
                    color: reached ? Colors.white : Colors.white54,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  maxText,
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ],
            ),
          ),
          Icon(
            reached ? Icons.check_circle : Icons.lock_outline,
            color: reached ? joseoGreen : Colors.white30,
          ),
        ],
      ),
    );
  }

  Widget _achievementCard(
    JoseoAchievementDefinition achievement,
    bool unlocked,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: unlocked
              ? joseoGold.withValues(alpha: .42)
              : joseoPurple.withValues(alpha: .2),
        ),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: unlocked ? 1 : .38,
            child: SafeAsset(
              asset: achievement.asset,
              width: 48,
              height: 48,
              fallback: Icons.workspace_premium_outlined,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  achievement.title,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  achievement.description,
                  style: const TextStyle(color: Colors.white54, fontSize: 9.5),
                ),
              ],
            ),
          ),
          Icon(
            unlocked ? Icons.check_circle : Icons.lock_outline,
            color: unlocked ? joseoGreen : Colors.white30,
          ),
        ],
      ),
    );
  }
}

// ============================================================
// GESTOR ADMINISTRADOR JOSEO
// ============================================================

class JoseoAdminPage extends StatelessWidget {
  const JoseoAdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: JoseoDataService.isAdmin(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: joseoBg,
            body: Center(
              child: CircularProgressIndicator(color: joseoGreen),
            ),
          );
        }

        if (snapshot.data != true) {
          return Scaffold(
            backgroundColor: joseoBg,
            appBar: AppBar(
              backgroundColor: joseoBg,
              title: const Text('Administración'),
            ),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Esta sección está reservada para administradores JOSEO.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        return DefaultTabController(
          length: 4,
          child: Scaffold(
            backgroundColor: joseoBg,
            appBar: AppBar(
              backgroundColor: joseoBg,
              surfaceTintColor: Colors.transparent,
              title: const Text(
                'Gestor JOSEO',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              bottom: const TabBar(
                indicatorColor: joseoGreen,
                labelColor: joseoGreen,
                tabs: [
                  Tab(icon: Icon(Icons.store_mall_directory), text: 'Lugares'),
                  Tab(icon: Icon(Icons.fact_check), text: 'Precios'),
                  Tab(icon: Icon(Icons.report_outlined), text: 'Reportes'),
                  Tab(icon: Icon(Icons.campaign), text: 'Publicidad'),
                ],
              ),
            ),
            body: const TabBarView(
              children: [
                _AdminPlacesTab(),
                _AdminPricesTab(),
                _AdminReportsTab(),
                _AdminAdsTab(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AdminPlaceItem {
  final int branchId;
  final int storeId;
  final String storeName;
  final String branchName;
  final String address;
  final String city;
  final String province;
  final double? latitude;
  final double? longitude;
  final DateTime? createdAt;

  const _AdminPlaceItem({
    required this.branchId,
    required this.storeId,
    required this.storeName,
    required this.branchName,
    required this.address,
    required this.city,
    required this.province,
    required this.latitude,
    required this.longitude,
    required this.createdAt,
  });

  factory _AdminPlaceItem.fromMap(Map<String, dynamic> row) {
    final storeRaw = row['stores'];
    final store = storeRaw is Map
        ? Map<String, dynamic>.from(storeRaw)
        : <String, dynamic>{};

    return _AdminPlaceItem(
      branchId: (row['id'] as num).toInt(),
      storeId: (row['store_id'] as num).toInt(),
      storeName: store['name']?.toString() ?? 'Negocio',
      branchName: row['name']?.toString() ?? 'Sucursal',
      address: row['address']?.toString() ?? '',
      city: row['city']?.toString() ?? '',
      province: row['province']?.toString() ?? '',
      latitude: (row['latitude'] as num?)?.toDouble(),
      longitude: (row['longitude'] as num?)?.toDouble(),
      createdAt: DateTime.tryParse(row['created_at']?.toString() ?? ''),
    );
  }
}

class _AdminPlacesTab extends StatefulWidget {
  const _AdminPlacesTab();

  @override
  State<_AdminPlacesTab> createState() => _AdminPlacesTabState();
}

class _AdminPlacesTabState extends State<_AdminPlacesTab> {
  late Future<List<_AdminPlaceItem>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _future = _load();
  }

  Future<List<_AdminPlaceItem>> _load() async {
    final rows = await Supabase.instance.client
        .from('branches')
        .select(
          'id, store_id, name, address, city, province, latitude, longitude, '
          'created_at, stores(name)',
        )
        .eq('verification_status', 'pending')
        .order('created_at', ascending: false);

    return rows
        .map(
          (row) => _AdminPlaceItem.fromMap(
            Map<String, dynamic>.from(row),
          ),
        )
        .toList();
  }

  Future<void> _review(int branchId, String decision) async {
    try {
      await Supabase.instance.client.rpc(
        'joseo_admin_review_place',
        params: {
          'p_branch_id': branchId,
          'p_decision': decision,
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            decision == 'approved'
                ? '✅ Lugar aprobado.'
                : '🚫 Lugar rechazado.',
          ),
        ),
      );
      setState(_refresh);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No pudimos actualizar el lugar.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_AdminPlaceItem>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: joseoGreen),
          );
        }

        final rows = snapshot.data ?? const <_AdminPlaceItem>[];
        if (rows.isEmpty) {
          return const _AdminEmptyState(
            icon: Icons.storefront_outlined,
            title: 'No hay lugares pendientes',
            subtitle: 'Las nuevas tiendas propuestas por la comunidad aparecerán aquí.',
          );
        }

        return RefreshIndicator(
          color: joseoGreen,
          onRefresh: () async {
            setState(_refresh);
            await _future;
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(14),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final item = rows[index];
              final location = [
                if (item.address.isNotEmpty) item.address,
                if (item.city.isNotEmpty) item.city,
                if (item.province.isNotEmpty) item.province,
              ].join(' • ');

              return Container(
                margin: const EdgeInsets.only(bottom: 11),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: joseoCard,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: joseoGold.withValues(alpha: .28)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.storefront, color: joseoGold),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            '${item.storeName} • ${item.branchName}',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                        const Text(
                          'PENDIENTE',
                          style: TextStyle(
                            color: joseoGold,
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        location,
                        style: const TextStyle(color: Colors.white60, fontSize: 10.5),
                      ),
                    ],
                    if (item.latitude != null && item.longitude != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'GPS ${item.latitude!.toStringAsFixed(6)}, ${item.longitude!.toStringAsFixed(6)}',
                        style: const TextStyle(color: joseoGreen, fontSize: 9.5),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _review(item.branchId, 'approved'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: joseoGreen,
                              foregroundColor: Colors.black,
                            ),
                            icon: const Icon(Icons.check),
                            label: const Text(
                              'Aprobar',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _review(item.branchId, 'rejected'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: joseoRed,
                              side: const BorderSide(color: joseoRed),
                            ),
                            icon: const Icon(Icons.close),
                            label: const Text(
                              'Rechazar',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _AdminPricesTab extends StatefulWidget {
  const _AdminPricesTab();

  @override
  State<_AdminPricesTab> createState() => _AdminPricesTabState();
}

class _AdminPricesTabState extends State<_AdminPricesTab> {
  late Future<List<JoseoCommunityPrice>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _future = JoseoDataService.loadCommunityPrices();
  }

  Future<void> _review(int priceId, String decision) async {
    try {
      await Supabase.instance.client.rpc(
        'joseo_admin_review_price',
        params: {
          'p_price_id': priceId,
          'p_decision': decision,
        },
      );
      if (!mounted) return;
      setState(_refresh);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No pudimos actualizar este precio.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<JoseoCommunityPrice>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: joseoGreen),
          );
        }

        final all = snapshot.data ?? const <JoseoCommunityPrice>[];
        final flagged = all.where((row) => row.incorrectCount > 0).toList()
          ..sort((a, b) => b.incorrectCount.compareTo(a.incorrectCount));

        if (flagged.isEmpty) {
          return const _AdminEmptyState(
            icon: Icons.fact_check_outlined,
            title: 'No hay precios reportados',
            subtitle: 'Cuando la comunidad marque un precio como incorrecto aparecerá aquí.',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(14),
          itemCount: flagged.length,
          itemBuilder: (context, index) {
            final item = flagged[index];
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: joseoCard,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: joseoRed.withValues(alpha: .25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.product,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${item.placeLabel} • RD\$ ${item.price.toStringAsFixed(2)}',
                    style: const TextStyle(color: Colors.white60, fontSize: 10.5),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${item.incorrectCount} reportan incorrecto • ${item.confirmedCount} confirman',
                    style: const TextStyle(color: joseoGold, fontSize: 10),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => JoseoPriceDetailPage(price: item),
                              ),
                            );
                          },
                          child: const Text('Revisar evidencia'),
                        ),
                      ),
                      const SizedBox(width: 7),
                      IconButton.filled(
                        tooltip: 'Mantener activo',
                        onPressed: () => _review(item.priceId, 'approved'),
                        style: IconButton.styleFrom(
                          backgroundColor: joseoGreen,
                          foregroundColor: Colors.black,
                        ),
                        icon: const Icon(Icons.check),
                      ),
                      const SizedBox(width: 5),
                      IconButton.outlined(
                        tooltip: 'Rechazar precio',
                        onPressed: () => _review(item.priceId, 'rejected'),
                        style: IconButton.styleFrom(foregroundColor: joseoRed),
                        icon: const Icon(Icons.block),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}


class _AdminContentReport {
  final int id;
  final int priceId;
  final String reason;
  final String details;
  final String status;
  final DateTime? createdAt;
  final String product;
  final String supermarket;
  final String branch;
  final double? price;

  const _AdminContentReport({
    required this.id,
    required this.priceId,
    required this.reason,
    required this.details,
    required this.status,
    required this.createdAt,
    required this.product,
    required this.supermarket,
    required this.branch,
    required this.price,
  });

  String get reasonLabel {
    switch (reason) {
      case 'wrong_price':
        return 'Precio falso o incorrecto';
      case 'inappropriate_photo':
        return 'Foto inapropiada';
      case 'spam':
        return 'Spam / publicidad';
      case 'nonexistent_business':
        return 'Negocio inexistente';
      case 'misleading_information':
        return 'Información engañosa';
      default:
        return 'Otro motivo';
    }
  }
}

class _AdminReportsTab extends StatefulWidget {
  const _AdminReportsTab();

  @override
  State<_AdminReportsTab> createState() => _AdminReportsTabState();
}

class _AdminReportsTabState extends State<_AdminReportsTab> {
  late Future<List<_AdminContentReport>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _future = _load();
  }

  Future<List<_AdminContentReport>> _load() async {
    final reportRows = await Supabase.instance.client
        .from('content_reports')
        .select('id, price_id, reason, details, status, created_at')
        .eq('status', 'pending')
        .order('created_at', ascending: false);

    if (reportRows.isEmpty) return const <_AdminContentReport>[];

    final prices = await JoseoDataService.loadCommunityPrices();
    final byId = <int, JoseoCommunityPrice>{
      for (final item in prices) item.priceId: item,
    };

    return reportRows.map((row) {
      final map = Map<String, dynamic>.from(row);
      final priceId = (map['price_id'] as num).toInt();
      final item = byId[priceId];

      return _AdminContentReport(
        id: (map['id'] as num).toInt(),
        priceId: priceId,
        reason: map['reason']?.toString() ?? 'other',
        details: map['details']?.toString() ?? '',
        status: map['status']?.toString() ?? 'pending',
        createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
        product: item?.product ?? 'Publicación #$priceId',
        supermarket: item?.supermarket ?? 'Establecimiento',
        branch: item?.branch ?? '',
        price: item?.price,
      );
    }).toList();
  }

  Future<void> _review(
    _AdminContentReport report, {
    required String decision,
    bool rejectPrice = false,
  }) async {
    try {
      await Supabase.instance.client.rpc(
        'joseo_admin_review_content_report',
        params: {
          'p_report_id': report.id,
          'p_decision': decision,
          'p_admin_note': rejectPrice
              ? 'Precio rechazado desde reporte de la comunidad.'
              : null,
          'p_reject_price': rejectPrice,
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            rejectPrice
                ? '🚫 Reporte resuelto y precio rechazado.'
                : decision == 'resolved'
                    ? '✅ Reporte marcado como resuelto.'
                    : 'Reporte descartado.',
          ),
        ),
      );
      setState(_refresh);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No pudimos actualizar el reporte.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_AdminContentReport>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: joseoGreen),
          );
        }

        final rows = snapshot.data ?? const <_AdminContentReport>[];
        if (rows.isEmpty) {
          return const _AdminEmptyState(
            icon: Icons.verified_user_outlined,
            title: 'No hay reportes pendientes',
            subtitle: 'Los reportes enviados por la comunidad aparecerán aquí.',
          );
        }

        return RefreshIndicator(
          color: joseoGreen,
          onRefresh: () async {
            setState(_refresh);
            await _future;
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(14),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final report = rows[index];
              final location = report.branch.isEmpty
                  ? report.supermarket
                  : '${report.supermarket} • ${report.branch}';

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: joseoCard,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: joseoRed.withValues(alpha: .35),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.flag_outlined, color: joseoRed),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            report.reasonLabel,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: joseoRed,
                            ),
                          ),
                        ),
                        const Text(
                          'PENDIENTE',
                          style: TextStyle(
                            color: joseoGold,
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      report.product,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      location,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 10.5,
                      ),
                    ),
                    if (report.price != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'RD\$ ${report.price!.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: joseoGreen,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                    if (report.details.trim().isNotEmpty) ...[
                      const SizedBox(height: 9),
                      Text(
                        report.details,
                        style: const TextStyle(
                          color: Colors.white70,
                          height: 1.35,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),
                    Text(
                      'Reporte #${report.id} • ${JoseoDataService.relativeDate(report.createdAt)}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _review(
                              report,
                              decision: 'resolved',
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: joseoGreen,
                              foregroundColor: Colors.black,
                            ),
                            icon: const Icon(Icons.check_circle_outline),
                            label: const Text('Resolver'),
                          ),
                        ),
                        const SizedBox(width: 7),
                        IconButton.outlined(
                          tooltip: 'Descartar reporte',
                          onPressed: () => _review(
                            report,
                            decision: 'dismissed',
                          ),
                          icon: const Icon(Icons.close),
                        ),
                        const SizedBox(width: 5),
                        IconButton.outlined(
                          tooltip: 'Rechazar precio',
                          onPressed: () => _review(
                            report,
                            decision: 'resolved',
                            rejectPrice: true,
                          ),
                          style: IconButton.styleFrom(
                            foregroundColor: joseoRed,
                          ),
                          icon: const Icon(Icons.block),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _AdminAdsTab extends StatefulWidget {
  const _AdminAdsTab();

  @override
  State<_AdminAdsTab> createState() => _AdminAdsTabState();
}

class _AdminAdsTabState extends State<_AdminAdsTab> {
  late Future<List<JoseoSponsoredOffer>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    _future = JoseoDataService.loadSponsoredOffers();
  }

  Future<void> _toggle(JoseoSponsoredOffer offer) async {
    try {
      await Supabase.instance.client
          .from('sponsored_offers')
          .update({
            'active': !offer.active,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', offer.id);
      if (mounted) setState(_refresh);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No pudimos actualizar la campaña.')),
      );
    }
  }

  Future<void> _delete(JoseoSponsoredOffer offer) async {
    try {
      await Supabase.instance.client
          .from('sponsored_offers')
          .delete()
          .eq('id', offer.id);

      if (offer.imagePath != null && offer.imagePath!.isNotEmpty) {
        try {
          await Supabase.instance.client.storage
              .from('sponsored-media')
              .remove([offer.imagePath!]);
        } catch (_) {}
      }

      if (mounted) setState(_refresh);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No pudimos eliminar la campaña.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FutureBuilder<List<JoseoSponsoredOffer>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: joseoGreen),
              );
            }

            final rows = snapshot.data ?? const <JoseoSponsoredOffer>[];
            if (rows.isEmpty) {
              return const _AdminEmptyState(
                icon: Icons.campaign_outlined,
                title: 'No hay campañas',
                subtitle: 'Usa el botón + para crear la primera publicidad patrocinada.',
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final offer = rows[index];
                final imageUrl = offer.publicImageUrl;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: joseoCard,
                    borderRadius: BorderRadius.circular(17),
                    border: Border.all(color: joseoGold.withValues(alpha: .22)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: joseoGold.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: imageUrl == null
                            ? const Icon(Icons.campaign, color: joseoGold)
                            : Image.network(
                                imageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const Icon(
                                  Icons.campaign,
                                  color: joseoGold,
                                ),
                              ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              offer.sponsorName,
                              style: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                            Text(
                              offer.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white60, fontSize: 10.5),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${offer.status.toUpperCase()} • ${offer.active ? 'ACTIVA' : 'PAUSADA'}',
                              style: TextStyle(
                                color: offer.active ? joseoGreen : joseoGold,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: offer.active ? 'Pausar' : 'Activar',
                        onPressed: () => _toggle(offer),
                        icon: Icon(
                          offer.active ? Icons.pause_circle : Icons.play_circle,
                          color: offer.active ? joseoGold : joseoGreen,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Eliminar',
                        onPressed: () => _delete(offer),
                        icon: const Icon(Icons.delete_outline, color: joseoRed),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
        Positioned(
          right: 18,
          bottom: 18,
          child: FloatingActionButton.extended(
            backgroundColor: joseoGreen,
            foregroundColor: Colors.black,
            onPressed: () async {
              final created = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const JoseoCreateSponsoredOfferPage()),
              );
              if (created == true && mounted) {
                setState(_refresh);
              }
            },
            icon: const Icon(Icons.add),
            label: const Text(
              'Nueva campaña',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ],
    );
  }
}

class JoseoCreateSponsoredOfferPage extends StatefulWidget {
  const JoseoCreateSponsoredOfferPage({super.key});

  @override
  State<JoseoCreateSponsoredOfferPage> createState() =>
      _JoseoCreateSponsoredOfferPageState();
}

class _JoseoCreateSponsoredOfferPageState
    extends State<JoseoCreateSponsoredOfferPage> {
  final _formKey = GlobalKey<FormState>();
  final _sponsorController = TextEditingController();
  final _titleController = TextEditingController();
  final _subtitleController = TextEditingController();
  final _priceController = TextEditingController();
  final _oldPriceController = TextEditingController();
  final _cityController = TextEditingController();
  final _daysController = TextEditingController(text: '30');
  final _picker = ImagePicker();
  XFile? _image;
  bool _saving = false;

  @override
  void dispose() {
    _sponsorController.dispose();
    _titleController.dispose();
    _subtitleController.dispose();
    _priceController.dispose();
    _oldPriceController.dispose();
    _cityController.dispose();
    _daysController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
    );
    if (image == null || !mounted) return;
    setState(() => _image = image);
  }

  String _extension(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return '.png';
    if (lower.endsWith('.webp')) return '.webp';
    if (lower.endsWith('.jpeg')) return '.jpeg';
    return '.jpg';
  }

  String _mime(String extension) {
    if (extension == '.png') return 'image/png';
    if (extension == '.webp') return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    setState(() => _saving = true);

    try {
      String? imagePath;
      if (_image != null) {
        final extension = _extension(_image!.path);
        imagePath = '${user.id}/ad_${DateTime.now().microsecondsSinceEpoch}$extension';
        await Supabase.instance.client.storage
            .from('sponsored-media')
            .upload(
              imagePath,
              File(_image!.path),
              fileOptions: FileOptions(
                upsert: false,
                contentType: _mime(extension),
              ),
            );
      }

      final days = int.tryParse(_daysController.text.trim()) ?? 30;
      final startsAt = DateTime.now().toUtc();
      final endsAt = startsAt.add(Duration(days: days.clamp(1, 365).toInt()));

      await Supabase.instance.client.from('sponsored_offers').insert({
        'sponsor_name': _sponsorController.text.trim(),
        'title': _titleController.text.trim(),
        'subtitle': _subtitleController.text.trim(),
        'price_text': _priceController.text.trim(),
        'old_price_text': _oldPriceController.text.trim(),
        'target_city': _cityController.text.trim(),
        'image_path': imagePath,
        'starts_at': startsAt.toIso8601String(),
        'ends_at': endsAt.toIso8601String(),
        'active': true,
        'status': 'approved',
        'priority': 0,
        'created_by': user.id,
      });

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No pudimos crear la campaña.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _decoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: joseoGreen),
      filled: true,
      fillColor: joseoCard,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(15)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: BorderSide(color: joseoPurple.withValues(alpha: .3)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: joseoGreen),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: joseoBg,
      appBar: AppBar(
        backgroundColor: joseoBg,
        title: const Text(
          'Nueva campaña',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GestureDetector(
              onTap: _saving ? null : _pickImage,
              child: Container(
                height: 170,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: joseoCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: joseoGold.withValues(alpha: .35)),
                ),
                child: _image == null
                    ? const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined, size: 52, color: joseoGold),
                          SizedBox(height: 8),
                          Text('Agregar imagen de campaña'),
                        ],
                      )
                    : Image.file(File(_image!.path), fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _sponsorController,
              decoration: _decoration('Patrocinador *', Icons.storefront),
              validator: (value) => (value?.trim().length ?? 0) < 2
                  ? 'Escribe el nombre del patrocinador.'
                  : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _titleController,
              decoration: _decoration('Título de campaña *', Icons.campaign),
              validator: (value) => (value?.trim().length ?? 0) < 3
                  ? 'Escribe un título.'
                  : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _subtitleController,
              decoration: _decoration('Descripción', Icons.notes),
              maxLines: 2,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _priceController,
                    decoration: _decoration('Precio / texto', Icons.attach_money),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: _oldPriceController,
                    decoration: _decoration('Precio anterior', Icons.money_off),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _cityController,
              decoration: _decoration('Ciudad / zona', Icons.location_city),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _daysController,
              keyboardType: TextInputType.number,
              decoration: _decoration('Duración en días', Icons.calendar_today),
              validator: (value) {
                final days = int.tryParse(value?.trim() ?? '');
                if (days == null || days < 1 || days > 365) {
                  return 'Usa entre 1 y 365 días.';
                }
                return null;
              },
            ),
            const SizedBox(height: 18),
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: joseoGreen,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Icon(Icons.publish),
              label: const Text(
                'Publicar campaña patrocinada',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Las campañas aparecen claramente marcadas como PUBLICIDAD y nunca afectan el Radar JOSEO.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 9.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _AdminEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: joseoGreen, size: 58),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// MI LISTA DE COMPRAS
// ============================================================

class JoseoShoppingListInfo {
  final String id;
  final String name;

  const JoseoShoppingListInfo({required this.id, required this.name});

  factory JoseoShoppingListInfo.fromJson(Map<String, dynamic> json) {
    return JoseoShoppingListInfo(
      id: json['id'].toString(),
      name: json['name']?.toString() ?? 'Mi compra',
    );
  }
}

class JoseoShoppingItem {
  final String id;
  final String listId;
  final String title;
  final String quantity;
  final int? productId;
  final double quantityValue;
  final String quantityUnit;
  final bool checked;
  final int position;

  const JoseoShoppingItem({
    required this.id,
    required this.listId,
    required this.title,
    required this.quantity,
    this.productId,
    this.quantityValue = 1,
    this.quantityUnit = 'unit',
    required this.checked,
    required this.position,
  });

  factory JoseoShoppingItem.fromJson(Map<String, dynamic> json) {
    return JoseoShoppingItem(
      id: json['id'].toString(),
      listId: json['list_id'].toString(),
      title: json['title']?.toString() ?? '',
      quantity: json['quantity']?.toString() ?? '',
      productId: (json['product_id'] as num?)?.toInt(),
      quantityValue: (json['quantity_value'] as num?)?.toDouble() ?? 1,
      quantityUnit: json['quantity_unit']?.toString() ?? 'unit',
      checked: json['checked'] == true,
      position: (json['position'] as num?)?.toInt() ?? 0,
    );
  }

  JoseoShoppingItem copyWith({bool? checked}) {
    return JoseoShoppingItem(
      id: id,
      listId: listId,
      title: title,
      quantity: quantity,
      productId: productId,
      quantityValue: quantityValue,
      quantityUnit: quantityUnit,
      checked: checked ?? this.checked,
      position: position,
    );
  }
}

class JoseoShoppingEstimate {
  final int storeId;
  final int branchId;
  final String supermarket;
  final String branch;
  final double distanceKm;
  final double total;
  final int matchedItems;
  final int totalItems;
  final List<String> missingItems;
  final DateTime? latestObservedAt;

  const JoseoShoppingEstimate({
    required this.storeId,
    required this.branchId,
    required this.supermarket,
    required this.branch,
    required this.distanceKm,
    required this.total,
    required this.matchedItems,
    required this.totalItems,
    required this.missingItems,
    required this.latestObservedAt,
  });

  bool get isComplete => matchedItems == totalItems && totalItems > 0;

  String get placeLabel {
    if (branch.trim().isEmpty || branch.toLowerCase() == supermarket.toLowerCase()) {
      return supermarket;
    }
    return '$supermarket • $branch';
  }
}

class JoseoShoppingListService {
  static SupabaseClient get _client => Supabase.instance.client;

  static User _requireUser() {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('Debes iniciar sesión para usar tu lista de compras.');
    }
    return user;
  }

  static Future<JoseoShoppingListInfo> loadOrCreateList() async {
    final user = _requireUser();
    final existing = await _client
        .from('shopping_lists')
        .select('id, name')
        .eq('user_id', user.id)
        .eq('is_archived', false)
        .order('created_at')
        .limit(1)
        .maybeSingle();

    if (existing != null) {
      return JoseoShoppingListInfo.fromJson(existing);
    }

    final created = await _client
        .from('shopping_lists')
        .insert({
          'user_id': user.id,
          'name': 'Mi compra',
        })
        .select('id, name')
        .single();

    return JoseoShoppingListInfo.fromJson(created);
  }

  static Future<List<JoseoShoppingItem>> loadItems(String listId) async {
    final user = _requireUser();
    List<dynamic> rows;

    try {
      rows = await _client
          .from('shopping_list_items')
          .select(
            'id, list_id, title, quantity, product_id, quantity_value, '
            'quantity_unit, checked, position',
          )
          .eq('user_id', user.id)
          .eq('list_id', listId)
          .order('checked')
          .order('position');
    } catch (_) {
      // Compatibilidad temporal mientras se aplica la migracion nueva.
      rows = await _client
          .from('shopping_list_items')
          .select('id, list_id, title, quantity, checked, position')
          .eq('user_id', user.id)
          .eq('list_id', listId)
          .order('checked')
          .order('position');
    }

    return rows
        .map((row) => JoseoShoppingItem.fromJson(row))
        .toList();
  }

  static Future<JoseoShoppingItem> addItem({
    required String listId,
    required String title,
    required String quantity,
    int? productId,
  }) async {
    final user = _requireUser();
    final parsedQuantity = _parseQuantity(quantity);
    final payload = <String, dynamic>{
      'list_id': listId,
      'user_id': user.id,
      'title': title.trim(),
      'quantity': quantity.trim(),
      'product_id': productId,
      'quantity_value': parsedQuantity.value,
      'quantity_unit': parsedQuantity.unit,
      'checked': false,
      'position': DateTime.now().microsecondsSinceEpoch,
    };

    dynamic created;
    try {
      created = await _client
          .from('shopping_list_items')
          .insert(payload)
          .select(
            'id, list_id, title, quantity, product_id, quantity_value, '
            'quantity_unit, checked, position',
          )
          .single();
    } catch (_) {
      // La lista sigue funcionando aunque el usuario aun no haya ejecutado
      // la migracion de estimaciones en Supabase.
      created = await _client
          .from('shopping_list_items')
          .insert({
            'list_id': listId,
            'user_id': user.id,
            'title': title.trim(),
            'quantity': quantity.trim(),
            'checked': false,
            'position': DateTime.now().microsecondsSinceEpoch,
          })
          .select('id, list_id, title, quantity, checked, position')
          .single();
    }

    return JoseoShoppingItem.fromJson(created);
  }

  static Future<JoseoShoppingItem> updateItem({
    required JoseoShoppingItem item,
    required String title,
    required String quantity,
  }) async {
    final user = _requireUser();
    final parsedQuantity = _parseQuantity(quantity);

    try {
      final updated = await _client
          .from('shopping_list_items')
          .update({
            'title': title.trim(),
            'quantity': quantity.trim(),
            'quantity_value': parsedQuantity.value,
            'quantity_unit': parsedQuantity.unit,
          })
          .eq('id', item.id)
          .eq('user_id', user.id)
          .select(
            'id, list_id, title, quantity, product_id, quantity_value, '
            'quantity_unit, checked, position',
          )
          .single();
      return JoseoShoppingItem.fromJson(updated);
    } catch (_) {
      final updated = await _client
          .from('shopping_list_items')
          .update({
            'title': title.trim(),
            'quantity': quantity.trim(),
          })
          .eq('id', item.id)
          .eq('user_id', user.id)
          .select('id, list_id, title, quantity, checked, position')
          .single();
      return JoseoShoppingItem.fromJson(updated);
    }
  }

  static Future<List<JoseoProductOption>> loadActiveProducts() async {
    final rows = await _client
        .from('products')
        .select('id, name')
        .eq('active', true)
        .order('name')
        .limit(5000);
    return rows
        .map((row) => JoseoProductOption.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  static Future<JoseoShoppingItem> linkProduct({
    required JoseoShoppingItem item,
    required JoseoProductOption product,
  }) async {
    final user = _requireUser();
    final updated = await _client
        .from('shopping_list_items')
        .update({
          'product_id': product.id,
          'title': product.name,
        })
        .eq('id', item.id)
        .eq('user_id', user.id)
        .select(
          'id, list_id, title, quantity, product_id, quantity_value, '
          'quantity_unit, checked, position',
        )
        .single();
    return JoseoShoppingItem.fromJson(updated);
  }

  static ({double value, String unit}) _parseQuantity(String raw) {
    final text = raw.trim().toLowerCase().replaceAll(',', '.');
    final match = RegExp(r'([0-9]+(?:\.[0-9]+)?)').firstMatch(text);
    final value = double.tryParse(match?.group(1) ?? '') ?? 1;

    String unit = 'unit';
    if (text.contains('kg')) unit = 'kg';
    if (text.contains('gram') || RegExp(r'\bgr?\b').hasMatch(text)) {
      unit = 'g';
    }
    if (text.contains('lit') || RegExp(r'\bl\b').hasMatch(text)) unit = 'l';
    if (text.contains('ml')) unit = 'ml';

    return (value: value > 0 ? value : 1, unit: unit);
  }

  static String _normalizeProductName(String value) {
    const accents = 'áéíóúüñÁÉÍÓÚÜÑ';
    const plain = 'aeiouunAEIOUUN';
    var normalized = value.trim().toLowerCase();
    for (var i = 0; i < accents.length; i++) {
      normalized = normalized.replaceAll(accents[i], plain[i].toLowerCase());
    }
    return normalized
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  static int? _resolveProductId(
    JoseoShoppingItem item,
    Map<String, JoseoProductOption> exactProducts,
    List<JoseoProductOption> allProducts,
  ) {
    if (item.productId != null) return item.productId;

    final normalizedTitle = _normalizeProductName(item.title);
    final exact = exactProducts[normalizedTitle];
    if (exact != null) return exact.id;

    final candidates = allProducts.where((product) {
      final normalizedProduct = _normalizeProductName(product.name);
      return normalizedProduct.contains(normalizedTitle) ||
          normalizedTitle.contains(normalizedProduct);
    }).toList();

    // Solo vinculamos automaticamente cuando hay una unica coincidencia.
    return candidates.length == 1 ? candidates.first.id : null;
  }

  static Future<List<JoseoShoppingEstimate>> estimateList({
    required List<JoseoShoppingItem> items,
    required double latitude,
    required double longitude,
    required double radiusKm,
    bool includeChecked = false,
  }) async {
    final selectedItems = items
        .where((item) => includeChecked || !item.checked)
        .toList();
    if (selectedItems.isEmpty) return const [];

    final allProducts = await loadActiveProducts();
    final exactProducts = <String, JoseoProductOption>{};
    for (final product in allProducts) {
      exactProducts[_normalizeProductName(product.name)] = product;
    }

    final resolvedIds = <String, int?>{};
    for (final item in selectedItems) {
      resolvedIds[item.id] = _resolveProductId(
        item,
        exactProducts,
        allProducts,
      );
    }

    final prices = await JoseoDataService.loadNearbyPrices(
      latitude: latitude,
      longitude: longitude,
      radiusKm: radiusKm,
    );
    final wantedProductIds = resolvedIds.values.whereType<int>().toSet();

    // store -> branch -> product -> mejor precio observado para esa sucursal.
    final byStore = <int, Map<int, Map<int, JoseoAllPrice>>>{};
    for (final price in prices) {
      if (!wantedProductIds.contains(price.productId)) continue;
      final branches = byStore.putIfAbsent(price.storeId, () => {});
      final products = branches.putIfAbsent(price.branchId, () => {});
      final previous = products[price.productId];
      if (previous == null ||
          price.price < previous.price ||
          (price.price == previous.price &&
              price.isOfficial &&
              !previous.isOfficial)) {
        products[price.productId] = price;
      }
    }

    final estimates = <JoseoShoppingEstimate>[];
    for (final storeEntry in byStore.entries) {
      JoseoShoppingEstimate? best;
      for (final branchEntry in storeEntry.value.entries) {
        final branchPrices = branchEntry.value;
        var total = 0.0;
        var matched = 0;
        DateTime? latest;
        final missing = <String>[];
        var distance = double.infinity;
        String supermarket = 'Supermercado';
        String branch = 'Sucursal';

        for (final item in selectedItems) {
          final productId = resolvedIds[item.id];
          final price = productId == null ? null : branchPrices[productId];
          if (price == null) {
            missing.add(item.title);
            continue;
          }
          matched++;
          total += price.price * item.quantityValue;
          supermarket = price.supermarket;
          branch = price.branch;
          distance = distance.isFinite
              ? (price.distanceKm < distance ? price.distanceKm : distance)
              : price.distanceKm;
          final observedAt = price.observedAt;
          if (observedAt != null &&
              (latest == null || observedAt.isAfter(latest))) {
            latest = observedAt;
          }
        }

        if (matched == 0) continue;
        final candidate = JoseoShoppingEstimate(
          storeId: storeEntry.key,
          branchId: branchEntry.key,
          supermarket: supermarket,
          branch: branch,
          distanceKm: distance.isFinite ? distance : 0,
          total: total,
          matchedItems: matched,
          totalItems: selectedItems.length,
          missingItems: missing,
          latestObservedAt: latest,
        );
        if (best == null ||
            candidate.matchedItems > best.matchedItems ||
            (candidate.matchedItems == best.matchedItems &&
                candidate.total < best.total)) {
          best = candidate;
        }
      }
      if (best != null) estimates.add(best);
    }

    estimates.sort((a, b) {
      final completeOrder = (b.isComplete ? 1 : 0).compareTo(a.isComplete ? 1 : 0);
      if (completeOrder != 0) return completeOrder;
      final matchOrder = b.matchedItems.compareTo(a.matchedItems);
      if (matchOrder != 0) return matchOrder;
      return a.total.compareTo(b.total);
    });
    return estimates;
  }

  static Future<void> setChecked(JoseoShoppingItem item, bool value) async {
    final user = _requireUser();
    await _client
        .from('shopping_list_items')
        .update({'checked': value})
        .eq('id', item.id)
        .eq('user_id', user.id);
  }

  static Future<void> deleteItem(JoseoShoppingItem item) async {
    final user = _requireUser();
    await _client
        .from('shopping_list_items')
        .delete()
        .eq('id', item.id)
        .eq('user_id', user.id);
  }

  static Future<void> clearChecked(String listId) async {
    final user = _requireUser();
    await _client
        .from('shopping_list_items')
        .delete()
        .eq('list_id', listId)
        .eq('user_id', user.id)
        .eq('checked', true);
  }

  static Future<void> renameList(String listId, String name) async {
    final user = _requireUser();
    await _client
        .from('shopping_lists')
        .update({'name': name.trim()})
        .eq('id', listId)
        .eq('user_id', user.id);
  }
}

class JoseoShoppingListPage extends StatefulWidget {
  const JoseoShoppingListPage({super.key});

  @override
  State<JoseoShoppingListPage> createState() => _JoseoShoppingListPageState();
}

class _JoseoShoppingListPageState extends State<JoseoShoppingListPage> {
  final _itemController = TextEditingController();
  final _quantityController = TextEditingController();

  JoseoShoppingListInfo? _list;
  List<JoseoShoppingItem> _items = const [];
  List<JoseoShoppingEstimate> _estimates = const [];
  bool _loading = true;
  bool _saving = false;
  bool _estimateLoading = false;
  bool _includeChecked = false;
  bool _showEstimateDetails = false;
  String? _error;
  String? _estimateError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _itemController.dispose();
    _quantityController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final list = await JoseoShoppingListService.loadOrCreateList();
      final items = await JoseoShoppingListService.loadItems(list.id);
      if (!mounted) return;
      setState(() {
        _list = list;
        _items = items;
        _loading = false;
      });
      unawaited(_refreshEstimates());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString().replaceFirst('StateError: ', '');
      });
    }
  }

  Future<void> _addItem() async {
    final list = _list;
    final title = _itemController.text.trim();
    if (list == null || title.isEmpty || _saving) return;

    setState(() => _saving = true);
    try {
      final item = await JoseoShoppingListService.addItem(
        listId: list.id,
        title: title,
        quantity: _quantityController.text,
      );
      if (!mounted) return;
      setState(() {
        _items = [..._items, item];
        _saving = false;
      });
      unawaited(_refreshEstimates());
      _itemController.clear();
      _quantityController.clear();
      FocusScope.of(context).unfocus();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showError('No pudimos agregar el artículo. $error');
    }
  }

  Future<void> _editItem(JoseoShoppingItem item) async {
    final titleController = TextEditingController(text: item.title);
    final quantityController = TextEditingController(text: item.quantity);
    final result = await showDialog<({String title, String quantity})>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: joseoCard,
        title: const Text('Editar artículo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Artículo'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: quantityController,
              decoration: const InputDecoration(
                labelText: 'Cantidad',
                hintText: 'Ej.: 2 uds.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final title = titleController.text.trim();
              if (title.isEmpty) return;
              Navigator.pop(
                dialogContext,
                (title: title, quantity: quantityController.text.trim()),
              );
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    titleController.dispose();
    quantityController.dispose();

    if (result == null) return;
    try {
      final updated = await JoseoShoppingListService.updateItem(
        item: item,
        title: result.title,
        quantity: result.quantity,
      );
      if (!mounted) return;
      setState(() {
        _items = _items
            .map((current) => current.id == item.id ? updated : current)
            .toList();
      });
      unawaited(_refreshEstimates());
    } catch (_) {
      if (mounted) _showError('No pudimos editar el artículo.');
    }
  }

  Future<void> _pickProductForItem(JoseoShoppingItem item) async {
    try {
      final products = await JoseoShoppingListService.loadActiveProducts();
      if (!mounted) return;
      final selected = await showDialog<JoseoProductOption>(
        context: context,
        builder: (dialogContext) {
          var query = '';
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final visible = products.where((product) {
                return product.name.toLowerCase().contains(query.toLowerCase());
              }).take(80).toList();
              return AlertDialog(
                backgroundColor: joseoCard,
                title: const Text('Vincular producto'),
                content: SizedBox(
                  width: double.maxFinite,
                  height: 430,
                  child: Column(
                    children: [
                      TextField(
                        autofocus: true,
                        onChanged: (value) => setDialogState(() => query = value),
                        decoration: const InputDecoration(
                          hintText: 'Buscar en el catálogo',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final product = visible[index];
                            return ListTile(
                              dense: true,
                              leading: const Icon(
                                Icons.shopping_basket_outlined,
                                color: joseoGreen,
                              ),
                              title: Text(product.name),
                              onTap: () => Navigator.pop(dialogContext, product),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Cancelar'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (selected == null) return;

      final updated = await JoseoShoppingListService.linkProduct(
        item: item,
        product: selected,
      );
      if (!mounted) return;
      setState(() {
        _items = _items
            .map((current) => current.id == item.id ? updated : current)
            .toList();
      });
      unawaited(_refreshEstimates());
    } catch (_) {
      if (mounted) _showError('No pudimos vincular ese producto.');
    }
  }

  Future<void> _toggleItem(JoseoShoppingItem item, bool value) async {
    final oldItems = _items;
    setState(() {
      _items = _items
          .map((current) => current.id == item.id
              ? current.copyWith(checked: value)
              : current)
          .toList();
    });

    try {
      await JoseoShoppingListService.setChecked(item, value);
      unawaited(_refreshEstimates());
    } catch (error) {
      if (!mounted) return;
      setState(() => _items = oldItems);
      _showError('No pudimos actualizar el artículo.');
    }
  }

  Future<void> _deleteItem(JoseoShoppingItem item) async {
    final oldItems = _items;
    setState(() {
      _items = _items.where((current) => current.id != item.id).toList();
    });

    try {
      await JoseoShoppingListService.deleteItem(item);
      unawaited(_refreshEstimates());
    } catch (error) {
      if (!mounted) return;
      setState(() => _items = oldItems);
      _showError('No pudimos eliminar el artículo.');
    }
  }

  Future<void> _clearChecked() async {
    final list = _list;
    if (list == null || !_items.any((item) => item.checked)) return;

    try {
      await JoseoShoppingListService.clearChecked(list.id);
      if (!mounted) return;
      setState(() {
        _items = _items.where((item) => !item.checked).toList();
      });
      unawaited(_refreshEstimates());
    } catch (_) {
      if (mounted) _showError('No pudimos limpiar los artículos marcados.');
    }
  }

  Future<void> _renameList() async {
    final list = _list;
    if (list == null) return;

    final controller = TextEditingController(text: list.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: joseoCard,
        title: const Text('Nombre de la lista'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Ej.: Compra de la semana'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (name == null || name.isEmpty || name == list.name) return;
    try {
      await JoseoShoppingListService.renameList(list.id, name);
      if (!mounted) return;
      setState(() => _list = JoseoShoppingListInfo(id: list.id, name: name));
    } catch (_) {
      if (mounted) _showError('No pudimos cambiar el nombre de la lista.');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _refreshEstimates() async {
    if (!mounted || _items.isEmpty) {
      if (mounted) {
        setState(() {
          _estimates = const [];
          _estimateError = null;
          _estimateLoading = false;
        });
      }
      return;
    }

    setState(() {
      _estimateLoading = true;
      _estimateError = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw StateError('Activa la ubicación para calcular tu compra.');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('No hay permiso de ubicación para calcular la lista.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final estimates = await JoseoShoppingListService.estimateList(
        items: _items,
        latitude: position.latitude,
        longitude: position.longitude,
        radiusKm: 20,
        includeChecked: _includeChecked,
      );

      if (!mounted) return;
      setState(() {
        _estimates = estimates;
        _estimateLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _estimateLoading = false;
        _estimates = const [];
        _estimateError = error.toString().replaceFirst('StateError: ', '');
      });
    }
  }

  Widget _estimateSection() {
    if (_items.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: joseoGreen.withValues(alpha: .25)),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => setState(
              () => _showEstimateDetails = !_showEstimateDetails,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                children: [
                  const Icon(Icons.price_check_rounded, color: joseoGreen),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Costo estimado de tu compra',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'Toca para ver el precio en cada supermercado',
                          style: TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Actualizar cálculo',
                    onPressed: _estimateLoading ? null : _refreshEstimates,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                  AnimatedRotation(
                    turns: _showEstimateDetails ? .5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: _showEstimateDetails
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: _estimateDetails(),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _estimateDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _includeChecked,
          onChanged: (value) {
            setState(() => _includeChecked = value);
            unawaited(_refreshEstimates());
          },
          title: const Text('Incluir artículos ya comprados'),
          subtitle: const Text('Por defecto solo calcula los pendientes.'),
          activeThumbColor: joseoGreen,
          activeTrackColor: joseoGreen.withValues(alpha: .45),
        ),
        if (_estimateLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: CircularProgressIndicator(color: joseoGreen),
            ),
          )
        else if (_estimateError != null)
          Text(
            _estimateError!,
            style: const TextStyle(color: joseoGold, height: 1.3),
          )
        else if (_estimates.isEmpty)
          const Text(
            'Aún no encontramos precios comparables cerca de tu ubicación.',
            style: TextStyle(color: Colors.white60, height: 1.3),
          )
        else
          ..._estimates.take(4).map(_estimateCard),
      ],
    );
  }

  Widget _estimateCard(JoseoShoppingEstimate estimate) {
    final updated = estimate.latestObservedAt == null
        ? 'Fecha no disponible'
        : 'Actualizado ${JoseoDataService.relativeDate(estimate.latestObservedAt)}';
    final missing = estimate.missingItems.isEmpty
        ? null
        : 'Faltan: ${estimate.missingItems.take(3).join(', ')}'
            '${estimate.missingItems.length > 3 ? '…' : ''}';

    return Container(
      margin: const EdgeInsets.only(top: 9),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: joseoBg.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: estimate.isComplete
              ? joseoGreen.withValues(alpha: .35)
              : joseoGold.withValues(alpha: .35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            estimate.isComplete
                ? Icons.check_circle_outline
                : Icons.info_outline,
            color: estimate.isComplete ? joseoGreen : joseoGold,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  estimate.placeLabel,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 3),
                Text(
                  'RD\$ ${estimate.total.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: joseoGreen,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  '${estimate.matchedItems} de ${estimate.totalItems} productos • '
                  '${estimate.distanceKm.toStringAsFixed(1)} km • $updated',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
                if (missing != null)
                  Text(
                    missing,
                    style: const TextStyle(color: joseoGold, fontSize: 11),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final checked = _items.where((item) => item.checked).length;
    final progress = _items.isEmpty ? 0.0 : checked / _items.length;

    return Scaffold(
      backgroundColor: joseoBg,
      appBar: AppBar(
        backgroundColor: joseoBg,
        title: Text(
          _list?.name ?? 'Mi lista de compras',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Cambiar nombre',
            onPressed: _list == null ? null : _renameList,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: joseoGreen))
          : _error != null
              ? _shoppingErrorView()
              : SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF25104A), Color(0xFF101C3C)],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: joseoPurple2.withValues(alpha: .4)),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.shopping_cart_checkout, color: joseoGreen),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '$checked de ${_items.length} artículos marcados',
                                    style: const TextStyle(fontWeight: FontWeight.w900),
                                  ),
                                ),
                                if (checked > 0)
                                  TextButton(
                                    onPressed: _clearChecked,
                                    child: const Text('Quitar marcados'),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 8,
                                backgroundColor: Colors.white10,
                                valueColor: const AlwaysStoppedAnimation(joseoGreen),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _estimateSection(),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: _itemController,
                                textCapitalization: TextCapitalization.sentences,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'Artículo',
                                  hintText: 'Ej.: Leche',
                                  prefixIcon: Icon(Icons.add_shopping_cart),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _quantityController,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _addItem(),
                                decoration: const InputDecoration(
                                  labelText: 'Cantidad',
                                  hintText: '2 uds.',
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            IconButton.filled(
                              tooltip: 'Agregar',
                              onPressed: _saving ? null : _addItem,
                              style: IconButton.styleFrom(
                                backgroundColor: joseoGreen,
                                foregroundColor: Colors.black,
                              ),
                              icon: _saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.black,
                                      ),
                                    )
                                  : const Icon(Icons.add),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: RefreshIndicator(
                          color: joseoGreen,
                          onRefresh: _load,
                          child: _items.isEmpty
                              ? ListView(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  children: const [
                                    SizedBox(height: 100),
                                    Icon(Icons.checklist_rounded, size: 72, color: Colors.white24),
                                    SizedBox(height: 12),
                                    Text(
                                      'Tu lista está vacía.\nAgrega lo que necesitas comprar.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: Colors.white54, height: 1.4),
                                    ),
                                  ],
                                )
                              : ListView.builder(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                                  itemCount: _items.length,
                                  itemBuilder: (context, index) {
                                    final item = _items[index];
                                    return Dismissible(
                                      key: ValueKey(item.id),
                                      direction: DismissDirection.endToStart,
                                      onDismissed: (_) => _deleteItem(item),
                                      background: Container(
                                        margin: const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.only(right: 20),
                                        alignment: Alignment.centerRight,
                                        decoration: BoxDecoration(
                                          color: joseoRed,
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                        child: const Icon(Icons.delete_outline),
                                      ),
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 8),
                                        decoration: BoxDecoration(
                                          color: item.checked
                                              ? joseoCard.withValues(alpha: .55)
                                              : joseoCard,
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(
                                            color: item.checked
                                                ? joseoGreen.withValues(alpha: .28)
                                                : Colors.white10,
                                          ),
                                        ),
                                        child: CheckboxListTile(
                                          value: item.checked,
                                          activeColor: joseoGreen,
                                          checkColor: Colors.black,
                                          onChanged: (value) =>
                                              _toggleItem(item, value ?? false),
                                          title: Text(
                                            item.title,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              decoration: item.checked
                                                  ? TextDecoration.lineThrough
                                                  : null,
                                              color: item.checked
                                                  ? Colors.white38
                                                  : Colors.white,
                                            ),
                                          ),
                                          subtitle: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              if (item.quantity.isNotEmpty)
                                                Text(
                                                  item.quantity,
                                                  style: const TextStyle(color: joseoGold),
                                                ),
                                              if (item.productId == null)
                                                TextButton.icon(
                                                  onPressed: () => _pickProductForItem(item),
                                                  style: TextButton.styleFrom(
                                                    padding: EdgeInsets.zero,
                                                    minimumSize: const Size(0, 28),
                                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                    alignment: Alignment.centerLeft,
                                                  ),
                                                  icon: const Icon(Icons.link, size: 15),
                                                  label: const Text('Vincular producto para calcular'),
                                                )
                                              else
                                                const Text(
                                                  'Producto vinculado al catálogo',
                                                  style: TextStyle(
                                                    color: joseoGreen,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          secondary: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                tooltip: 'Editar',
                                                onPressed: () => _editItem(item),
                                                icon: const Icon(
                                                  Icons.edit_outlined,
                                                  color: Colors.white54,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: 'Eliminar',
                                                onPressed: () => _deleteItem(item),
                                                icon: const Icon(
                                                  Icons.delete_outline,
                                                  color: Colors.white38,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _shoppingErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, color: joseoGold, size: 56),
            const SizedBox(height: 12),
            Text(
              _error ?? 'No pudimos cargar la lista.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 15),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// PERFIL
// ============================================================

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final user = Supabase.instance.client.auth.currentUser;

        if (user == null) {
          return _guestProfile(context);
        }

        return _authenticatedProfile(context, user);
      },
    );
  }

  Widget _pageBackground({required Widget child}) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D062A), joseoBg],
          ),
        ),
        child: child,
      ),
    );
  }

  Future<void> _requestAccountDeletion(BuildContext context) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: joseoCard,
          title: const Text('Eliminar mi cuenta'),
          content: const Text(
            'Esta acción inicia una solicitud para eliminar tu cuenta y tus datos personales asociados. '
            'Tus aportes comunitarios podrán ser anonimizados cuando sea necesario para mantener la integridad de las comparaciones y prevenir fraude. '
            'Una vez procesada la eliminación, no podrás recuperar la cuenta.',
            style: TextStyle(color: Colors.white70, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text(
                'Continuar',
                style: TextStyle(color: joseoRed, fontWeight: FontWeight.w900),
              ),
            ),
          ],
        );
      },
    );

    if (firstConfirm != true || !context.mounted) return;

    final finalConfirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: joseoCard,
          title: const Text('Confirmación final'),
          content: Text(
            'La solicitud se enviará para la cuenta ${user.email ?? 'JOSEO'}. ¿Deseas continuar?',
            style: const TextStyle(color: Colors.white70, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('No, volver'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: joseoRed,
                foregroundColor: Colors.white,
              ),
              child: const Text(
                'Sí, eliminar mi cuenta',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        );
      },
    );

    if (finalConfirm != true || !context.mounted) return;

    try {
      await Supabase.instance.client.from('account_deletion_requests').upsert(
        {
          'user_id': user.id,
          'email': user.email,
          'status': 'pending',
          'requested_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id',
      );

      if (!context.mounted) return;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: joseoCard,
            title: const Text('Solicitud recibida'),
            content: const Text(
              'JOSEO registró tu solicitud de eliminación. Cerraremos tu sesión ahora. '
              'Si necesitas dar seguimiento, escribe a Anibal.santanac@gmail.com desde el correo asociado a tu cuenta.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text(
                  'Entendido',
                  style: TextStyle(color: joseoGreen, fontWeight: FontWeight.w900),
                ),
              ),
            ],
          );
        },
      );

      await Supabase.instance.client.auth.signOut();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No pudimos registrar la solicitud. Inténtalo nuevamente o escribe a Anibal.santanac@gmail.com.',
          ),
        ),
      );
    }
  }

  Widget _legalAndPrivacySection(BuildContext context) {
    Widget tile({
      required IconData icon,
      required String title,
      required JoseoLegalDocument document,
    }) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: joseoGreen),
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.white38),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => JoseoLegalDocumentPage(document: document),
            ),
          );
        },
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: joseoPurple.withValues(alpha: .25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.policy_outlined, color: joseoGold, size: 20),
              SizedBox(width: 8),
              Text(
                'Legal y privacidad',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          tile(
            icon: Icons.privacy_tip_outlined,
            title: 'Política de Privacidad',
            document: JoseoLegalDocument.privacy,
          ),
          const Divider(height: 1, color: Colors.white10),
          tile(
            icon: Icons.description_outlined,
            title: 'Términos de Uso',
            document: JoseoLegalDocument.terms,
          ),
          const Divider(height: 1, color: Colors.white10),
          tile(
            icon: Icons.groups_outlined,
            title: 'Normas de la Comunidad',
            document: JoseoLegalDocument.community,
          ),
          const SizedBox(height: 6),
          if (Supabase.instance.client.auth.currentUser != null) ...[
            const Divider(height: 1, color: Colors.white10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.delete_forever_outlined,
                color: joseoRed,
              ),
              title: const Text(
                'Eliminar mi cuenta',
                style: TextStyle(
                  color: joseoRed,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
              subtitle: const Text(
                'Solicita la eliminación de tu cuenta y datos personales asociados.',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 9.5,
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: Colors.white38,
              ),
              onTap: () => _requestAccountDeletion(context),
            ),
          ],
          const SizedBox(height: 5),
          const Text(
            'Contacto legal y privacidad: Anibal.santanac@gmail.com',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }

  Widget _shoppingListSection(
    BuildContext context, {
    required bool authenticated,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          if (authenticated) {
            await Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => const JoseoShoppingListPage(),
              ),
            );
            return;
          }

          await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const JoseoAuthPage()),
          );
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF164B31), Color(0xFF1D1245)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: joseoGreen.withValues(alpha: .48)),
          ),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 27,
                backgroundColor: Color(0x2286E019),
                child: Icon(
                  Icons.checklist_rounded,
                  color: joseoGreen,
                  size: 31,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Mi lista de compras',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      authenticated
                          ? 'Crea tu lista, agrega productos y marca lo que ya compraste.'
                          : 'Inicia sesión para crear y guardar tu lista personal.',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                authenticated ? Icons.chevron_right : Icons.lock_outline,
                color: joseoGreen,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _guestProfile(BuildContext context) {
    return _pageBackground(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 110),
        child: Column(
          children: [
            const Text(
              'Mi perfil',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 30),
            const SafeAsset(
              asset: JoseoAssets.joseParado,
              width: 180,
              height: 220,
              fallback: Icons.person_outline,
            ),
            const SizedBox(height: 12),
            const Text(
              'Únete a la comunidad JOSEO',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 9),
            const Text(
              'Puedes consultar precios sin cuenta. Para publicar, validar precios y ganar XP necesitas registrarte.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.45),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => const JoseoAuthPage()),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: joseoGreen,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                child: const Text(
                  'Iniciar sesión',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () async {
                  await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const JoseoAuthPage(startInRegisterMode: true),
                    ),
                  );
                },
                child: const Text('Crear cuenta'),
              ),
            ),
            const SizedBox(height: 20),
            _shoppingListSection(context, authenticated: false),
            const SizedBox(height: 20),
            _legalAndPrivacySection(context),
          ],
        ),
      ),
    );
  }

  Widget _authenticatedProfile(BuildContext context, User user) {
    final metadata = user.userMetadata ?? <String, dynamic>{};
    final metadataName = metadata['full_name']?.toString().trim() ?? '';
    final email = user.email ?? 'Cuenta JOSEO';
    final fallbackName = email.contains('@') ? email.split('@').first : 'Joseador';
    final displayName = metadataName.isNotEmpty ? metadataName : fallbackName;
    final emailConfirmed = user.emailConfirmedAt != null;

    return _pageBackground(
      child: FutureBuilder<JoseoUserStats>(
        future: JoseoDataService.loadMyStats(),
        builder: (context, statsSnapshot) {
          final stats = statsSnapshot.data ?? JoseoUserStats.zero;
          final level = JoseoGamification.levelForXp(stats.xp);
          final progress = JoseoGamification.progressForXp(stats.xp);

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 110),
            child: Column(
              children: [
                const Row(
                  children: [
                    Spacer(),
                    Text(
                      'Mi perfil',
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
                    ),
                    Spacer(),
                    Icon(Icons.verified_user_outlined, color: joseoGreen),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF211044), Color(0xFF12102F)],
                    ),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: joseoPurple2.withValues(alpha: .35)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 82,
                        height: 82,
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [joseoGold, joseoGreen]),
                        ),
                        child: const ClipOval(
                          child: SafeAsset(
                            asset: JoseoAssets.logoCirculo,
                            fit: BoxFit.cover,
                            fallback: Icons.person,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 10.5,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  emailConfirmed
                                      ? Icons.check_circle
                                      : Icons.mark_email_unread_outlined,
                                  color: emailConfirmed ? joseoGreen : joseoGold,
                                  size: 15,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  emailConfirmed ? 'Correo confirmado' : 'Confirma tu correo',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _shoppingListSection(context, authenticated: true),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _statCard(
                        JoseoAssets.compararPrecios,
                        '${stats.publishedPrices}',
                        'Precios\npublicados',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _statCard(
                        JoseoAssets.escudo,
                        '${stats.validatedPrices}',
                        'Precios\nvalidados',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _statCard(
                        JoseoAssets.moneda2,
                        '${stats.xp}',
                        'XP\nJOSEO',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _gamificationSummary(context, stats, level, progress),
                const SizedBox(height: 16),
                _communityStats(stats),
                const SizedBox(height: 16),
                FutureBuilder<bool>(
                  future: JoseoDataService.isAdmin(),
                  builder: (context, adminSnapshot) {
                    if (adminSnapshot.data != true) {
                      return const SizedBox.shrink();
                    }

                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const JoseoAdminPage()),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: joseoGold,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.admin_panel_settings),
                          label: const Text(
                            'Abrir Gestor Administrador',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: joseoCard,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: joseoPurple.withValues(alpha: .25)),
                  ),
                  child: const Row(
                    children: [
                      SafeAsset(
                        asset: JoseoAssets.escudo,
                        width: 45,
                        height: 45,
                        fallback: Icons.shield_outlined,
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Tus aportes tienen trazabilidad',
                              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'JOSEO asocia cada precio a tu cuenta, sucursal, fecha y evidencia disponible.',
                              style: TextStyle(color: Colors.white60, fontSize: 10.5),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _legalAndPrivacySection(context),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await Supabase.instance.client.auth.signOut();
                      } on AuthException catch (error) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(error.message)),
                        );
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: joseoRed,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: joseoRed.withValues(alpha: .65)),
                    ),
                    icon: const Icon(Icons.logout),
                    label: const Text(
                      'Cerrar sesión',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'JOSEO 1.0 • Los porcentajes del Radar se calculan con datos comunitarios recientes y reglas de confianza.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white30, fontSize: 8.5),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _communityStats(JoseoUserStats stats) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Expanded(
            child: _smallCommunityStat(
              Icons.fact_check_outlined,
              '${stats.confirmationsMade}',
              'Validaciones hechas',
            ),
          ),
          Container(width: 1, height: 40, color: Colors.white10),
          Expanded(
            child: _smallCommunityStat(
              Icons.thumb_up_alt_outlined,
              '${stats.receivedConfirmations}',
              'Confirmaciones recibidas',
            ),
          ),
          Container(width: 1, height: 40, color: Colors.white10),
          Expanded(
            child: _smallCommunityStat(
              Icons.store_mall_directory_outlined,
              '${stats.uniqueBranches}',
              'Sucursales aportadas',
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallCommunityStat(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: joseoGreen, size: 20),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 7.8),
        ),
      ],
    );
  }

  Widget _gamificationSummary(
    BuildContext context,
    JoseoUserStats stats,
    JoseoLevelDefinition level,
    double progress,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF28124D), Color(0xFF102044)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: joseoGold.withValues(alpha: .35)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              SafeAsset(
                asset: level.asset,
                width: 52,
                height: 52,
                fallback: Icons.emoji_events_outlined,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'NIVEL ACTUAL',
                      style: TextStyle(
                        color: joseoGold,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .7,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      level.name,
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${stats.xp} XP',
                      style: const TextStyle(
                        color: joseoGreen,
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const GamificationPage()),
                  );
                },
                icon: const Icon(Icons.chevron_right, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: joseoBg,
              valueColor: const AlwaysStoppedAnimation(joseoGreen),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.spaceAround,
            spacing: 6,
            runSpacing: 6,
            children: [
              ProfileBadge(JoseoAssets.moneda1, unlocked: stats.firstJoseo),
              ProfileBadge(JoseoAssets.corona, unlocked: stats.frequentPublisher),
              ProfileBadge(JoseoAssets.escudo, unlocked: stats.verifiedHunter),
              ProfileBadge(JoseoAssets.ganaPuntos, unlocked: stats.storeExplorer),
              ProfileBadge(JoseoAssets.corazon, unlocked: stats.communityHeart),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statCard(String image, String value, String label) {
    return Container(
      height: 100,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: joseoCard,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.white.withValues(alpha: .05)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SafeAsset(asset: image, width: 31, height: 31),
          const SizedBox(height: 4),
          FittedBox(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 8.5,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileBadge extends StatelessWidget {
  final String asset;
  final bool unlocked;

  const ProfileBadge(
    this.asset, {
    super.key,
    this.unlocked = true,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Opacity(
          opacity: unlocked ? 1 : .38,
          child: Container(
            width: 65,
            height: 65,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: joseoCard2,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: unlocked ? joseoGold : Colors.white24,
              ),
            ),
            child: SafeAsset(asset: asset),
          ),
        ),
        if (!unlocked)
          const Positioned(
            right: -4,
            bottom: -4,
            child: CircleAvatar(
              radius: 11,
              backgroundColor: joseoBg,
              child: Icon(
                Icons.lock,
                size: 13,
                color: Colors.white70,
              ),
            ),
          ),
      ],
    );
  }
}
