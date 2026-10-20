import 'dart:io';
import 'dart:async';

import 'package:flutter_edge_detection/flutter_edge_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'form_widgets.dart';
import 'passenger_home.dart' show RPColors;
import '../services/profile_photo_service.dart';

const String _kNameField = 'name';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({
    super.key,
    required this.initialName,
    required this.initialPhone,
    required this.email,
    this.avatarImageUrl,
  });

  final String initialName;
  final String initialPhone;
  final String email;
  final String? avatarImageUrl;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _vehicleStatusSubscription;

  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;

  final _makeController = TextEditingController();
  final _modelController = TextEditingController();
  final _colorController = TextEditingController();
  final _plateController = TextEditingController();
  final _capacityController = TextEditingController();

  File? _registrationDocumentImage;
  String? _registrationDocumentUrl;
  String? _vehicleVerificationStatus;
  String? _vehicleRejectionReason;
  String? _originalVehicleMake;
  String? _originalVehicleModel;
  String? _originalVehicleColor;
  String? _originalPlateNumber;
  int? _originalSeatCapacity;

  bool _uploadingRegistrationDocument = false;
  bool _saving = false;
  bool _uploadingPhoto = false;
  bool _loadingAccount = true;
  bool _isDriver = false;
  bool _vehicleExists = false;

  String? _avatarUrl;

  @override
  void initState() {
    super.initState();

    _avatarUrl = widget.avatarImageUrl;
    _nameController = TextEditingController(text: widget.initialName);
    _phoneController = TextEditingController(text: widget.initialPhone);

    _loadAccountAndVehicle();
  }

  @override
  void dispose() {
    _vehicleStatusSubscription?.cancel();

    _nameController.dispose();
    _phoneController.dispose();
    _makeController.dispose();
    _modelController.dispose();
    _colorController.dispose();
    _plateController.dispose();
    _capacityController.dispose();
    super.dispose();
  }

  void _listenToVehicleStatus(String uid) {
    _vehicleStatusSubscription?.cancel();

    _vehicleStatusSubscription = FirebaseFirestore.instance
        .collection('vehicles')
        .doc(uid)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || !snapshot.exists) return;

            final data = snapshot.data();
            if (data == null) return;

            setState(() {
              _vehicleVerificationStatus = data['verificationStatus']
                  ?.toString();

              _vehicleRejectionReason = data['rejectionReason']?.toString();

              _registrationDocumentUrl = data['registrationDocumentUrl']
                  ?.toString();
            });
          },
          onError: (error) {
            debugPrint('Vehicle status listener error: $error');
          },
        );
  }

  Future<void> _loadAccountAndVehicle() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      if (mounted) {
        setState(() => _loadingAccount = false);
        _showMessage('You are not signed in.');
      }
      return;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      if (!mounted) return;

      final role = userDoc.data()?['role']?.toString().trim().toLowerCase();

      _isDriver = role == 'driver';

      if (_isDriver) {
        _listenToVehicleStatus(uid);
      }

      if (_isDriver) {
        // One vehicle document per driver, using the driver's UID
        // as the document ID. This prevents duplicate vehicles.
        final vehicleDoc = await FirebaseFirestore.instance
            .collection('vehicles')
            .doc(uid)
            .get();

        if (!mounted) return;

        final data = vehicleDoc.data();

        _vehicleExists = vehicleDoc.exists;

        if (data != null) {
          _makeController.text = data['vehicleMake']?.toString() ?? '';
          _modelController.text = data['vehicleModel']?.toString() ?? '';
          _colorController.text = data['vehicleColor']?.toString() ?? '';
          _plateController.text = data['plateNumber']?.toString() ?? '';

          final capacity = data['seatCapacity'];
          _capacityController.text = capacity?.toString() ?? '';

          _originalVehicleMake = _makeController.text.trim();
          _originalVehicleModel = _modelController.text.trim();
          _originalVehicleColor = _colorController.text.trim();
          _originalPlateNumber = _normalizePlateNumber(_plateController.text);
          _originalSeatCapacity = int.tryParse(_capacityController.text.trim());

          _registrationDocumentUrl = data['registrationDocumentUrl']
              ?.toString();

          _vehicleVerificationStatus = data['verificationStatus']?.toString();

          _vehicleRejectionReason = data['rejectionReason']?.toString();
        }
      }
    } catch (e) {
      debugPrint('Load profile and vehicle error: $e');

      if (mounted) {
        _showMessage('Could not load your vehicle details.');
      }
    } finally {
      if (mounted) {
        setState(() => _loadingAccount = false);
      }
    }
  }

  String? _validateName(String? value) {
    final v = (value ?? '').trim();

    if (v.isEmpty) return 'Please enter your name.';
    if (v.length < 2) return 'Name is too short.';

    return null;
  }

  String _normalizePlateNumber(String value) {
    return value.toUpperCase().replaceAll(RegExp(r'\s+'), '');
  }

  String? _validatePenangPlateNumber(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Vehicle plate number is required.';
    }

    final plate = _normalizePlateNumber(value);

    // Standard Penang series: P + 1–2 series letters + 1–4 digits.
    // Excludes I, O and Z from the series letters.
    final penangPlate = RegExp(r'^P[A-HJ-NP-Y]{1,2}[1-9][0-9]{0,3}$');

    if (!penangPlate.hasMatch(plate)) {
      return 'Enter a valid Penang plate number, e.g. PSG2439.';
    }

    return null;
  }

  String? _validateVehicleText(String? value, String fieldName) {
    final text = (value ?? '').trim();

    if (text.isEmpty) {
      return 'Please enter $fieldName.';
    }

    if (text.length < 2) {
      return '$fieldName must contain at least 2 characters.';
    }

    if (text.length > 40) {
      return '$fieldName cannot exceed 40 characters.';
    }

    return null;
  }

  String? _validateCapacity(String? value) {
    final capacity = int.tryParse((value ?? '').trim());

    if (capacity == null) {
      return 'Enter the number of passenger seats.';
    }

    if (capacity < 1 || capacity > 4) {
      return 'Enter between 1 and 4 passenger seats.';
    }

    return null;
  }

  Future<void> _scanCarRegistrationDocument() async {
    if (_uploadingRegistrationDocument || _saving) return;

    setState(() => _uploadingRegistrationDocument = true);

    try {
      final directory = await getApplicationSupportDirectory();

      final imagePath = p.join(
        directory.path,
        'vehicle_registration_${DateTime.now().millisecondsSinceEpoch}.jpeg',
      );

      final success = await FlutterEdgeDetection.detectEdge(
        imagePath,
        canUseGallery: true,
        androidScanTitle: 'Scan Vehicle Registration',
        androidCropTitle: 'Adjust Edges',
        androidCropBlackWhiteTitle: 'Black & White',
        androidCropReset: 'Reset',
      );

      if (!mounted) return;

      if (success && await File(imagePath).exists()) {
        setState(() {
          _registrationDocumentImage = File(imagePath);
        });

        _showMessage('Vehicle registration document selected.');
      }
    } on EdgeDetectionException catch (e) {
      if (!mounted) return;

      _showMessage('Document scan failed: ${e.message}');
    } catch (e) {
      debugPrint('Vehicle registration scan error: $e');

      if (!mounted) return;

      _showMessage('Could not open the document scanner.');
    } finally {
      if (mounted) {
        setState(() => _uploadingRegistrationDocument = false);
      }
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;
    if (_saving || _loadingAccount) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      _showMessage('You are not signed in.');
      return;
    }

    setState(() => _saving = true);

    try {
      final firestore = FirebaseFirestore.instance;
      final batch = firestore.batch();

      final userRef = firestore.collection('users').doc(uid);

      String? uploadedRegistrationUrl;

      if (_isDriver && _registrationDocumentImage != null) {
        final storageRef = FirebaseStorage.instance
            .ref()
            .child('users')
            .child(uid)
            .child('vehicle_registration.jpg');

        await storageRef.putFile(_registrationDocumentImage!);
        uploadedRegistrationUrl = await storageRef.getDownloadURL();
      }

      if (_isDriver) {
        final vehicleRef = firestore.collection('vehicles').doc(uid);

        final newMake = _makeController.text.trim();
        final newModel = _modelController.text.trim();
        final newColor = _colorController.text.trim();
        final newPlate = _normalizePlateNumber(_plateController.text);
        final newCapacity = int.parse(_capacityController.text.trim());

        // Compare the submitted details with the details originally loaded.
        // Ignore letter case and surrounding whitespace for text fields.
        final vehicleDetailsChanged =
            _vehicleExists &&
            (newMake.toLowerCase() !=
                    (_originalVehicleMake ?? '').trim().toLowerCase() ||
                newModel.toLowerCase() !=
                    (_originalVehicleModel ?? '').trim().toLowerCase() ||
                newColor.toLowerCase() !=
                    (_originalVehicleColor ?? '').trim().toLowerCase() ||
                newPlate != (_originalPlateNumber ?? '') ||
                newCapacity != _originalSeatCapacity);

        final registrationDocumentChanged = uploadedRegistrationUrl != null;

        final needsReapproval =
            vehicleDetailsChanged || registrationDocumentChanged;

        final vehicleData = <String, dynamic>{
          'driverId': uid,
          'vehicleMake': newMake,
          'vehicleModel': newModel,
          'vehicleColor': newColor,
          'plateNumber': newPlate,
          'seatCapacity': newCapacity,
          'updatedAt': FieldValue.serverTimestamp(),
        };

        if (!_vehicleExists) {
          // New vehicles cannot be used until approved.
          vehicleData['verificationStatus'] = registrationDocumentChanged
              ? 'pending'
              : 'not_submitted';

          vehicleData['isActive'] = false;
          vehicleData['createdAt'] = FieldValue.serverTimestamp();
        } else if (needsReapproval) {
          // A change to any registered vehicle detail requires review again.
          vehicleData['verificationStatus'] = 'pending';
          vehicleData['isActive'] = false;

          // Clear the old rejection reason when a new review is requested.
          vehicleData['rejectionReason'] = FieldValue.delete();
        }

        if (uploadedRegistrationUrl != null) {
          vehicleData['registrationDocumentUrl'] = uploadedRegistrationUrl;
        }

        batch.set(vehicleRef, vehicleData, SetOptions(merge: true));
      }
      batch.set(userRef, {
        _kNameField: _nameController.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Profile and vehicle changes succeed or fail together.
      await batch.commit();

      if (!mounted) return;

      if (_isDriver) {
        setState(() {
          _vehicleExists = true;
          _originalVehicleMake = _makeController.text.trim();
          _originalVehicleModel = _modelController.text.trim();
          _originalVehicleColor = _colorController.text.trim();
          _originalPlateNumber = _normalizePlateNumber(_plateController.text);
          _originalSeatCapacity = int.tryParse(_capacityController.text.trim());

          _registrationDocumentImage = null;
        });
      }

      _showMessage(
        _isDriver ? 'Profile and vehicle details saved.' : 'Profile updated.',
      );

      // Stay on the Edit Profile page.
    } catch (e) {
      debugPrint('Edit profile error: $e');

      if (!mounted) return;

      _showMessage('Could not save your changes. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _changePhoto() async {
    if (_uploadingPhoto) return;

    setState(() => _uploadingPhoto = true);

    try {
      final result = await changeProfilePhoto(
        context,
        hasPhoto: (_avatarUrl ?? '').isNotEmpty,
      );

      if (!mounted) return;

      setState(() {
        _uploadingPhoto = false;

        if (result != null) {
          _avatarUrl = result.isEmpty ? null : result;
        }
      });
    } catch (e) {
      debugPrint('Change profile photo error: $e');

      if (!mounted) return;

      setState(() => _uploadingPhoto = false);
      _showMessage('Could not update your profile photo.');
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: rpAppBar('Edit Profile'),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: _buildAvatar()),
                const SizedBox(height: 24),

                _buildProfileSection(),

                if (_loadingAccount) ...[
                  const SizedBox(height: 24),
                  const Center(
                    child: CircularProgressIndicator(color: RPColors.teal),
                  ),
                ] else if (_isDriver) ...[
                  const SizedBox(height: 24),
                  _buildVehicleSection(),
                ],

                const SizedBox(height: 24),

                RPPrimaryButton(
                  label: 'Save Changes',
                  icon: Icons.check_circle_outline,
                  loading: _saving || _uploadingRegistrationDocument,
                  onPressed: _save,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfileSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const RPFieldLabel('Full Name'),
          TextFormField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            decoration: rpInputDecoration(hint: 'Your full name'),
            validator: _validateName,
          ),
          const SizedBox(height: 16),

          const RPFieldLabel('Phone Number'),
          TextFormField(
            controller: _phoneController,
            readOnly: true,
            style: const TextStyle(color: RPColors.textGrey),
            decoration: rpInputDecoration(readOnly: true),
          ),
          const SizedBox(height: 6),
          const Text(
            'Your number is verified. Contact support to change it.',
            style: TextStyle(fontSize: 11, color: RPColors.textGrey),
          ),
          const SizedBox(height: 16),

          const RPFieldLabel('Email'),
          TextFormField(
            initialValue: widget.email,
            readOnly: true,
            style: const TextStyle(color: RPColors.textGrey),
            decoration: rpInputDecoration(readOnly: true),
          ),
          const SizedBox(height: 6),
          const Text(
            "Email is your login and can't be changed here.",
            style: TextStyle(fontSize: 11, color: RPColors.textGrey),
          ),
        ],
      ),
    );
  }

  Widget _buildVehicleVerificationStatus() {
    final status = (_vehicleVerificationStatus ?? 'not_submitted')
        .trim()
        .toLowerCase();

    final Color statusColor;
    final IconData statusIcon;
    final String statusLabel;
    final String statusMessage;

    switch (status) {
      case 'approved':
        statusColor = Colors.green.shade700;
        statusIcon = Icons.check_circle;
        statusLabel = 'Approved';
        statusMessage =
            'Your vehicle registration has been approved. '
            'You can go online if your driver account is also approved.';

      case 'pending':
        statusColor = Colors.orange.shade800;
        statusIcon = Icons.hourglass_top;
        statusLabel = 'Pending Review';
        statusMessage =
            'Your registration document has been submitted. '
            'Please wait for an admin to review it. You cannot go online yet.';

      case 'rejected':
        statusColor = Colors.red.shade700;
        statusIcon = Icons.cancel;
        statusLabel = 'Rejected';
        statusMessage =
            'Your vehicle registration was rejected. '
            'Please review the reason below and submit a replacement document.';

      case 'not_submitted':
        statusColor = RPColors.textGrey;
        statusIcon = Icons.upload_file;
        statusLabel = 'Not Submitted';
        statusMessage =
            'Please upload your vehicle registration document '
            'to begin verification. You cannot go online yet.';

      default:
        statusColor = RPColors.textGrey;
        statusIcon = Icons.help_outline;
        statusLabel = 'Status Unknown';
        statusMessage =
            'We could not identify your vehicle verification status. '
            'Please contact support if this continues.';
    }

    final rejectionReason = (_vehicleRejectionReason ?? '').trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.08),
        border: Border.all(color: statusColor.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, color: statusColor, size: 24),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Vehicle Verification Status',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: RPColors.textDark,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                color: statusColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),

          const SizedBox(height: 10),

          Text(
            statusMessage,
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: RPColors.textDark,
            ),
          ),

          if (status == 'rejected') ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, color: statusColor, size: 18),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'Reason provided by admin',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    rejectionReason.isNotEmpty
                        ? rejectionReason
                        : 'No rejection reason was provided. '
                              'Please contact support for clarification.',
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
          ],

          if (status == 'pending' && _registrationDocumentImage != null) ...[
            const SizedBox(height: 8),
            const Text(
              'Your replacement document will be reviewed after you save.',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVehicleSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.directions_car_outlined,
                color: RPColors.teal,
                size: 22,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Vehicle Details',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: RPColors.textDark,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Enter the details of your active vehicle. '
            'Passenger capacity excludes the driver.',
            style: TextStyle(fontSize: 12, color: RPColors.textGrey),
          ),
          const SizedBox(height: 20),

          const RPFieldLabel('Vehicle Make'),
          TextFormField(
            controller: _makeController,
            textCapitalization: TextCapitalization.words,
            decoration: rpInputDecoration(hint: 'e.g. Perodua'),
            validator: (value) => _validateVehicleText(value, 'Vehicle make'),
          ),
          const SizedBox(height: 16),

          const RPFieldLabel('Vehicle Model'),
          TextFormField(
            controller: _modelController,
            textCapitalization: TextCapitalization.words,
            decoration: rpInputDecoration(hint: 'e.g. Myvi'),
            validator: (value) => _validateVehicleText(value, 'Vehicle model'),
          ),
          const SizedBox(height: 16),

          const RPFieldLabel('Vehicle Colour'),
          TextFormField(
            controller: _colorController,
            textCapitalization: TextCapitalization.words,
            decoration: rpInputDecoration(hint: 'e.g. Silver'),
            validator: (value) => _validateVehicleText(value, 'Vehicle colour'),
          ),
          const SizedBox(height: 16),

          const RPFieldLabel('Plate Number'),
          TextFormField(
            controller: _plateController,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
            decoration: rpInputDecoration(hint: 'e.g. PSG2439'),
            validator: _validatePenangPlateNumber,
          ),
          const SizedBox(height: 16),

          const RPFieldLabel('Passenger Seat Capacity'),
          TextFormField(
            controller: _capacityController,
            keyboardType: TextInputType.number,
            decoration: rpInputDecoration(hint: 'Enter 1 to 4 seats'),
            validator: _validateCapacity,
          ),
          const SizedBox(height: 20),

          _buildVehicleVerificationStatus(),

          const SizedBox(height: 20),

          const RPFieldLabel('Vehicle Registration Document'),

          Container(
            width: double.infinity,
            height: 190,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: RPColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: _registrationDocumentImage != null
                ? Image.file(_registrationDocumentImage!, fit: BoxFit.contain)
                : (_registrationDocumentUrl != null &&
                      _registrationDocumentUrl!.isNotEmpty)
                ? Image.network(
                    _registrationDocumentUrl!,
                    fit: BoxFit.contain,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;

                      return const Center(
                        child: CircularProgressIndicator(color: RPColors.teal),
                      );
                    },
                    errorBuilder: (_, _, _) {
                      return const Center(
                        child: Text('Could not display the saved document.'),
                      );
                    },
                  )
                : const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 42,
                          color: RPColors.teal,
                        ),
                        SizedBox(height: 8),
                        Text('No registration document uploaded'),
                      ],
                    ),
                  ),
          ),

          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _saving || _uploadingRegistrationDocument
                  ? null
                  : _scanCarRegistrationDocument,
              icon: const Icon(Icons.document_scanner_outlined),
              label: Text(
                _registrationDocumentImage != null ||
                        (_registrationDocumentUrl ?? '').isNotEmpty
                    ? 'Replace Registration Document'
                    : 'Scan Registration Document',
              ),
            ),
          ),

          if (_registrationDocumentImage != null) ...[
            const SizedBox(height: 6),
            const Text(
              'A new document will be submitted for admin review when you save.',
              style: TextStyle(fontSize: 11, color: RPColors.textGrey),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    final url = _avatarUrl;

    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        children: [
          Container(
            width: 96,
            height: 96,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: RPColors.teal, width: 3),
            ),
            child: CircleAvatar(
              backgroundColor: RPColors.teal,
              backgroundImage: url != null ? NetworkImage(url) : null,
              child: _uploadingPhoto
                  ? const CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    )
                  : (url == null
                        ? const Icon(
                            Icons.person,
                            color: Colors.white,
                            size: 40,
                          )
                        : null),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: InkWell(
              onTap: _changePhoto,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: RPColors.teal, width: 1.5),
                ),
                child: const Icon(
                  Icons.camera_alt,
                  size: 16,
                  color: RPColors.teal,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
