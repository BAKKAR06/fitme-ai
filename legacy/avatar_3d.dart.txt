import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:three_js/three_js.dart' as three;

class AvatarBodyProfile {
  AvatarBodyProfile._();

  static final AvatarBodyProfile current = AvatarBodyProfile._();

  double height = 178;
  double weight = 74;
  double chest = 96;
  double waist = 81;
  double hips = 94;

  String get signature =>
      '${height.round()}-${weight.round()}-${chest.round()}-'
      '${waist.round()}-${hips.round()}';

  AvatarBodyProfile snapshot() {
    final copy = AvatarBodyProfile._();
    copy.height = height;
    copy.weight = weight;
    copy.chest = chest;
    copy.waist = waist;
    copy.hips = hips;
    return copy;
  }
}

class Avatar3DPreview extends StatelessWidget {
  const Avatar3DPreview({
    super.key,
    this.height = 250,
    this.autoRotate = false,
  });

  final double height;
  final bool autoRotate;

  @override
  Widget build(BuildContext context) {
    final p = AvatarBodyProfile.current.snapshot();
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: height,
        color: const Color(0xFF111217),
        child: Avatar3DCanvas(
          key: ValueKey(p.signature),
          profile: p,
          autoRotate: autoRotate,
        ),
      ),
    );
  }
}

class Avatar3DScreen extends StatefulWidget {
  const Avatar3DScreen({
    super.key,
    this.initialHeight,
    this.initialWeight,
    this.initialChest,
    this.initialWaist,
    this.initialHips,
  });

  final double? initialHeight;
  final double? initialWeight;
  final double? initialChest;
  final double? initialWaist;
  final double? initialHips;

  @override
  State<Avatar3DScreen> createState() => _Avatar3DScreenState();
}

class _Avatar3DScreenState extends State<Avatar3DScreen> {
  late double height;
  late double weight;
  late double chest;
  late double waist;
  late double hips;
  int previewRevision = 0;

  @override
  void initState() {
    super.initState();
    final p = AvatarBodyProfile.current;

    height = widget.initialHeight ?? p.height;
    weight = widget.initialWeight ?? p.weight;
    chest = widget.initialChest ?? p.chest;
    waist = widget.initialWaist ?? p.waist;
    hips = widget.initialHips ?? p.hips;

    _saveProfile();
  }

  void _saveProfile() {
    final p = AvatarBodyProfile.current;
    p.height = height;
    p.weight = weight;
    p.chest = chest;
    p.waist = waist;
    p.hips = hips;
  }

  void _refreshPreview() {
    _saveProfile();
    setState(() => previewRevision++);
  }

  @override
  Widget build(BuildContext context) {
    final previewProfile = AvatarBodyProfile.current.snapshot();

    return Scaffold(
      appBar: AppBar(
        title: const Text('3D-аватар'),
        actions: [
          TextButton(
            onPressed: () {
              _saveProfile();
              Navigator.pop(context);
            },
            child: const Text('Готово'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Container(
            height: 410,
            decoration: BoxDecoration(
              color: const Color(0xFF111217),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white10),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Avatar3DCanvas(
                    key: ValueKey(
                      '$previewRevision-${previewProfile.signature}',
                    ),
                    profile: previewProfile,
                    autoRotate: false,
                  ),
                ),
                const Positioned(
                  left: 16,
                  bottom: 14,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xB3101117),
                      borderRadius: BorderRadius.all(Radius.circular(99)),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.threesixty, size: 17),
                          SizedBox(width: 6),
                          Text('Проведи влево / вправо'),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Параметры тела',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'Отпусти ползунок — пропорции 3D-модели обновятся.',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 16),
          _AvatarSlider(
            label: 'Рост',
            value: height,
            min: 145,
            max: 210,
            unit: 'см',
            onChanged: (v) => setState(() => height = v),
            onChangeEnd: (_) => _refreshPreview(),
          ),
          _AvatarSlider(
            label: 'Вес',
            value: weight,
            min: 40,
            max: 140,
            unit: 'кг',
            onChanged: (v) => setState(() => weight = v),
            onChangeEnd: (_) => _refreshPreview(),
          ),
          _AvatarSlider(
            label: 'Грудь',
            value: chest,
            min: 70,
            max: 140,
            unit: 'см',
            onChanged: (v) => setState(() => chest = v),
            onChangeEnd: (_) => _refreshPreview(),
          ),
          _AvatarSlider(
            label: 'Талия',
            value: waist,
            min: 55,
            max: 130,
            unit: 'см',
            onChanged: (v) => setState(() => waist = v),
            onChangeEnd: (_) => _refreshPreview(),
          ),
          _AvatarSlider(
            label: 'Бёдра',
            value: hips,
            min: 70,
            max: 150,
            unit: 'см',
            onChanged: (v) => setState(() => hips = v),
            onChangeEnd: (_) => _refreshPreview(),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF17181E),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: Color(0xFFB9AEFF)),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'MVP-аватар строится по параметрам тела. '
                    'Он показывает пропорции пользователя и служит '
                    'основой для будущей 3D-примерки и подбора размера.',
                    style: TextStyle(color: Colors.white70),
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

class _AvatarSlider extends StatelessWidget {
  const _AvatarSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String unit;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        children: [
          Row(
            children: [
              Text(label),
              const Spacer(),
              Text(
                '${value.round()} $unit',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}

class Avatar3DCanvas extends StatefulWidget {
  const Avatar3DCanvas({
    super.key,
    required this.profile,
    this.autoRotate = true,
  });

  final AvatarBodyProfile profile;
  final bool autoRotate;

  @override
  State<Avatar3DCanvas> createState() => _Avatar3DCanvasState();
}

class _Avatar3DCanvasState extends State<Avatar3DCanvas> {
  late three.ThreeJS threeJs;
  three.OrbitControls? controls;
  three.Group? avatarGroup;

  @override
  void initState() {
    super.initState();
    threeJs = three.ThreeJS(
      onSetupComplete: () {
        if (mounted) setState(() {});
      },
      setup: setup,
      settings: three.Settings(localClippingEnabled: true),
    );
  }

  @override
  void dispose() {
    controls?.dispose();
    threeJs.dispose();
    super.dispose();
  }

  three.Mesh _ellipsoid(
    three.Material material, {
    required double x,
    required double y,
    required double z,
    required double sx,
    required double sy,
    required double sz,
    int widthSegments = 32,
    int heightSegments = 22,
  }) {
    final mesh = three.Mesh(
      three.SphereGeometry(1, widthSegments, heightSegments),
      material,
    );
    mesh.position.setValues(x, y, z);
    mesh.scale.setValues(sx, sy, sz);
    return mesh;
  }

  three.Mesh _taperedLimb(
    three.Material material, {
    required double x,
    required double y,
    required double z,
    required double topRadius,
    required double bottomRadius,
    required double length,
    double rotationZ = 0,
    double depthScale = 0.90,
    int segments = 30,
  }) {
    final mesh = three.Mesh(
      three.CylinderGeometry(topRadius, bottomRadius, length, segments),
      material,
    );
    mesh.position.setValues(x, y, z);
    mesh.rotation.z = rotationZ;
    mesh.scale.z = depthScale;
    return mesh;
  }

  Future<void> setup() async {
    threeJs.camera = three.PerspectiveCamera(
      31,
      threeJs.width / threeJs.height,
      0.1,
      100,
    );
    threeJs.camera.position.setValues(0, 2.45, 8.15);

    threeJs.scene = three.Scene();

    final ambient = three.AmbientLight(0xffffff, 1.28);
    threeJs.scene.add(ambient);

    final keyLight = three.PointLight(0xffffff, 2.25);
    keyLight.position.setValues(3.4, 5.8, 4.8);
    threeJs.scene.add(keyLight);

    final fillLight = three.PointLight(0x8B7CF6, 1.15);
    fillLight.position.setValues(-4.2, 3.4, 2.8);
    threeJs.scene.add(fillLight);

    final rimLight = three.PointLight(0xCFC8FF, 0.80);
    rimLight.position.setValues(0, 4.8, -4.0);
    threeJs.scene.add(rimLight);

    avatarGroup = _buildAvatar(widget.profile);
    threeJs.scene.add(avatarGroup!);

    final floorMaterial = three.MeshPhongMaterial.fromMap({
      'color': 0x24252D,
      'transparent': true,
      'opacity': 0.95,
      'shininess': 8,
    });
    final floor = three.Mesh(
      three.CylinderGeometry(1.58, 1.58, 0.07, 56),
      floorMaterial,
    );
    floor.position.setValues(0, -0.035, 0);
    threeJs.scene.add(floor);

    controls = three.OrbitControls(threeJs.camera, threeJs.globalKey);
    controls?.enablePan = false;
    controls?.enableZoom = false;
    controls?.minDistance = 7.2;
    controls?.maxDistance = 7.2;
    controls?.minPolarAngle = math.pi / 2;
    controls?.maxPolarAngle = math.pi / 2;

    threeJs.camera.lookAt(three.Vector3(0, 2.35, 0));

    if (widget.autoRotate) {
      threeJs.addAnimationEvent((dt) {
        final group = avatarGroup;
        if (group != null) {
          group.rotation.y += 0.0017;
        }
      });
    }
  }

  three.Group _buildAvatar(AvatarBodyProfile p) {
    final group = three.Group();

    final h = (p.height / 178.0).clamp(0.84, 1.18).toDouble();
    final meters = p.height / 100.0;
    final bmi = p.weight / math.max(1.0, meters * meters);
    final mass = math
        .pow((bmi / 23.35).clamp(0.60, 1.85), 0.34)
        .toDouble()
        .clamp(0.92, 1.12);
    final chest = (p.chest / 96.0).clamp(0.78, 1.35).toDouble();
    final waist = (p.waist / 81.0).clamp(0.72, 1.45).toDouble();
    final hips = (p.hips / 94.0).clamp(0.78, 1.40).toDouble();

    final skin = three.MeshPhongMaterial.fromMap({
      'color': 0xB9B3D6,
      'shininess': 20,
    });
    final skinSoft = three.MeshPhongMaterial.fromMap({
      'color': 0xC7C2DE,
      'shininess': 16,
    });
    final top = three.MeshPhongMaterial.fromMap({
      'color': 0x7566D8,
      'shininess': 14,
    });
    final shorts = three.MeshPhongMaterial.fromMap({
      'color': 0x454856,
      'shininess': 10,
    });
    final shoe = three.MeshPhongMaterial.fromMap({
      'color': 0x2E3038,
      'shininess': 18,
    });

    // Human-like vertical proportions.
    final footY = 0.12;
    final ankleY = 0.29 * h;
    final kneeY = 1.16 * h;
    final hipY = 2.05 * h;
    final waistY = 2.47 * h;
    final chestY = 2.95 * h;
    final shoulderY = 3.30 * h;
    final neckY = 3.58 * h;
    final headY = 4.02 * h;

    final thighGap = 0.23 * hips;
    final legMass = mass * (0.92 + hips * 0.08);
    final thighTop = (0.190 * legMass * hips).clamp(0.15, 0.27);
    final kneeRadius = (0.135 * legMass).clamp(0.11, 0.19);
    final calfTop = (0.145 * legMass).clamp(0.115, 0.205);
    final ankleRadius = (0.095 * legMass).clamp(0.080, 0.145);

    // Feet.
    group.add(
      _ellipsoid(
        shoe,
        x: -thighGap,
        y: footY,
        z: 0.12,
        sx: 0.19 * legMass,
        sy: 0.105 * h,
        sz: 0.38 * mass,
      ),
    );
    group.add(
      _ellipsoid(
        shoe,
        x: thighGap,
        y: footY,
        z: 0.12,
        sx: 0.19 * legMass,
        sy: 0.105 * h,
        sz: 0.38 * mass,
      ),
    );

    // Lower legs.
    final lowerLegLength = kneeY - ankleY;
    group.add(
      _taperedLimb(
        skin,
        x: -thighGap,
        y: ankleY + lowerLegLength / 2,
        z: 0,
        topRadius: calfTop,
        bottomRadius: ankleRadius,
        length: lowerLegLength,
        depthScale: 0.88,
      ),
    );
    group.add(
      _taperedLimb(
        skin,
        x: thighGap,
        y: ankleY + lowerLegLength / 2,
        z: 0,
        topRadius: calfTop,
        bottomRadius: ankleRadius,
        length: lowerLegLength,
        depthScale: 0.88,
      ),
    );

    // Knees.
    group.add(
      _ellipsoid(
        skinSoft,
        x: -thighGap,
        y: kneeY,
        z: 0,
        sx: kneeRadius,
        sy: kneeRadius * 1.08,
        sz: kneeRadius * 0.90,
      ),
    );
    group.add(
      _ellipsoid(
        skinSoft,
        x: thighGap,
        y: kneeY,
        z: 0,
        sx: kneeRadius,
        sy: kneeRadius * 1.08,
        sz: kneeRadius * 0.90,
      ),
    );

    // Thighs.
    final thighLength = hipY - kneeY;
    group.add(
      _taperedLimb(
        skin,
        x: -thighGap,
        y: kneeY + thighLength / 2,
        z: 0,
        topRadius: thighTop,
        bottomRadius: kneeRadius * 0.95,
        length: thighLength,
        depthScale: 0.94,
      ),
    );
    group.add(
      _taperedLimb(
        skin,
        x: thighGap,
        y: kneeY + thighLength / 2,
        z: 0,
        topRadius: thighTop,
        bottomRadius: kneeRadius * 0.95,
        length: thighLength,
        depthScale: 0.94,
      ),
    );

    // Shorts / pelvis smoothly overlap the top of the thighs.
    group.add(
      _ellipsoid(
        shorts,
        x: 0,
        y: hipY + 0.12 * h,
        z: 0,
        sx: 0.47 * hips * mass,
        sy: 0.27 * h,
        sz: 0.285 * hips * mass,
      ),
    );

    // Abdomen + chest as overlapping ellipsoids: much softer silhouette
    // than the old cylinder torso.
    group.add(
      _ellipsoid(
        top,
        x: 0,
        y: waistY,
        z: 0,
        sx: 0.395 * waist * mass,
        sy: 0.42 * h,
        sz: 0.225 * waist * mass,
      ),
    );
    group.add(
      _ellipsoid(
        top,
        x: 0,
        y: chestY,
        z: 0,
        sx: 0.485 * chest * mass,
        sy: 0.49 * h,
        sz: 0.25 * chest * mass,
      ),
    );

    // Shoulders.
    final shoulderX = (0.55 * chest * mass).clamp(0.50, 0.76);
    final shoulderR = (0.145 * mass).clamp(0.12, 0.19);
    group.add(
      _ellipsoid(
        top,
        x: -shoulderX,
        y: shoulderY,
        z: 0,
        sx: shoulderR * 1.18,
        sy: shoulderR,
        sz: shoulderR * 0.92,
      ),
    );
    group.add(
      _ellipsoid(
        top,
        x: shoulderX,
        y: shoulderY,
        z: 0,
        sx: shoulderR * 1.18,
        sy: shoulderR,
        sz: shoulderR * 0.92,
      ),
    );

    // Arms with elbow joints and tapered forearms.
    final upperArmLength = 0.77 * h;
    final forearmLength = 0.70 * h;
    final armTop = (0.125 * mass).clamp(0.095, 0.175);
    final elbowR = (0.105 * mass).clamp(0.080, 0.145);
    final wristR = (0.078 * mass).clamp(0.060, 0.105);
    final armAngle = 0.075;

    final elbowY = shoulderY - upperArmLength;
    final handY = elbowY - forearmLength - 0.18 * h;

    group.add(
      _taperedLimb(
        skin,
        x: -shoulderX - 0.03,
        y: shoulderY - upperArmLength / 2,
        z: 0,
        topRadius: armTop,
        bottomRadius: elbowR,
        length: upperArmLength,
        rotationZ: -armAngle,
        depthScale: 0.88,
      ),
    );
    group.add(
      _taperedLimb(
        skin,
        x: shoulderX + 0.03,
        y: shoulderY - upperArmLength / 2,
        z: 0,
        topRadius: armTop,
        bottomRadius: elbowR,
        length: upperArmLength,
        rotationZ: armAngle,
        depthScale: 0.88,
      ),
    );

    final elbowX = shoulderX + math.sin(armAngle) * upperArmLength * 0.45;

    group.add(
      _ellipsoid(
        skinSoft,
        x: -elbowX,
        y: elbowY,
        z: 0,
        sx: elbowR,
        sy: elbowR,
        sz: elbowR * 0.92,
      ),
    );
    group.add(
      _ellipsoid(
        skinSoft,
        x: elbowX,
        y: elbowY,
        z: 0,
        sx: elbowR,
        sy: elbowR,
        sz: elbowR * 0.92,
      ),
    );

    group.add(
      _taperedLimb(
        skin,
        x: -elbowX - 0.025,
        y: elbowY - forearmLength / 2,
        z: 0.015,
        topRadius: elbowR * 0.95,
        bottomRadius: wristR,
        length: forearmLength,
        rotationZ: -0.025,
        depthScale: 0.86,
      ),
    );
    group.add(
      _taperedLimb(
        skin,
        x: elbowX + 0.025,
        y: elbowY - forearmLength / 2,
        z: 0.015,
        topRadius: elbowR * 0.95,
        bottomRadius: wristR,
        length: forearmLength,
        rotationZ: 0.025,
        depthScale: 0.86,
      ),
    );

    group.add(
      _ellipsoid(
        skinSoft,
        x: -elbowX - 0.04,
        y: handY,
        z: 0.04,
        sx: wristR * 1.12,
        sy: 0.20 * h,
        sz: wristR * 0.82,
      ),
    );
    group.add(
      _ellipsoid(
        skinSoft,
        x: elbowX + 0.04,
        y: handY,
        z: 0.04,
        sx: wristR * 1.12,
        sy: 0.20 * h,
        sz: wristR * 0.82,
      ),
    );

    // Neck.
    final neckRadius = (0.145 * mass).clamp(0.115, 0.20);
    group.add(
      _taperedLimb(
        skin,
        x: 0,
        y: neckY,
        z: 0,
        topRadius: neckRadius * 0.92,
        bottomRadius: neckRadius,
        length: 0.34 * h,
        depthScale: 0.96,
      ),
    );

    // Neutral fashion mannequin head: no toy-like face.
    final headW = 0.255 * h * (0.99 + mass * 0.01);
    final headH = 0.33 * h;
    final headD = 0.235 * h;
    group.add(
      _ellipsoid(
        skinSoft,
        x: 0,
        y: headY,
        z: 0,
        sx: headW,
        sy: headH,
        sz: headD,
      ),
    );

    return group;
  }

  @override
  Widget build(BuildContext context) {
    return threeJs.build();
  }
}
