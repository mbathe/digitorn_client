import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../services/auth_service.dart';
import '../../services/onboarding_service.dart';
import '../../theme/app_theme.dart';
import '../ds/ds.dart';

enum _Mode { signIn, register }

/// Premium login page — split hero on wide viewports, stacked on
/// mobile. All visuals come from the DS components: aurora bg,
/// brand mark, inputs, buttons. Authentication logic is unchanged.
class LoginPage extends StatefulWidget {
  final VoidCallback onAuthenticated;

  const LoginPage({super.key, required this.onAuthenticated});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with TickerProviderStateMixin {
  final _loginFormKey = GlobalKey<FormState>();
  final _registerFormKey = GlobalKey<FormState>();

  final _loginUser = TextEditingController();
  final _loginPass = TextEditingController();
  final _regUser = TextEditingController();
  final _regEmail = TextEditingController();
  final _regPass = TextEditingController();
  final _urlCtrl = TextEditingController();

  bool _hideLoginPass = true;
  bool _hideRegPass = true;
  bool _showAdvanced = false;
  _Mode _mode = _Mode.signIn;

  late final AnimationController _entry;

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = AuthService().baseUrl;
    _entry = AnimationController(
      vsync: this,
      duration: DsDuration.hero,
    )..forward();
  }

  @override
  void dispose() {
    _entry.dispose();
    _loginUser.dispose();
    _loginPass.dispose();
    _regUser.dispose();
    _regEmail.dispose();
    _regPass.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _doLogin() async {
    if (!_loginFormKey.currentState!.validate()) return;
    AuthService().baseUrl = _urlCtrl.text.trim();
    final ok = await AuthService().login(
      username: _loginUser.text.trim(),
      password: _loginPass.text,
    );
    if (ok && mounted) widget.onAuthenticated();
  }

  Future<void> _doRegister() async {
    if (!_registerFormKey.currentState!.validate()) return;
    AuthService().baseUrl = _urlCtrl.text.trim();
    final ok = await AuthService().register(
      username: _regUser.text.trim(),
      password: _regPass.text,
      email: _regEmail.text.trim().isEmpty ? null : _regEmail.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      await OnboardingService().resetAccount();
      if (mounted) widget.onAuthenticated();
    }
  }

  void _toggleMode() {
    setState(
        () => _mode = _mode == _Mode.signIn ? _Mode.register : _Mode.signIn);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: DsAuroraBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (ctx, box) {
              final wide = box.maxWidth >= 980;
              final form = _FormPanel(
                entry: _entry,
                mode: _mode,
                loginKey: _loginFormKey,
                registerKey: _registerFormKey,
                loginUser: _loginUser,
                loginPass: _loginPass,
                regUser: _regUser,
                regEmail: _regEmail,
                regPass: _regPass,
                urlCtrl: _urlCtrl,
                hideLoginPass: _hideLoginPass,
                hideRegPass: _hideRegPass,
                showAdvanced: _showAdvanced,
                onToggleLoginPass: () =>
                    setState(() => _hideLoginPass = !_hideLoginPass),
                onToggleRegPass: () =>
                    setState(() => _hideRegPass = !_hideRegPass),
                onToggleAdvanced: () =>
                    setState(() => _showAdvanced = !_showAdvanced),
                onSignIn: _doLogin,
                onRegister: _doRegister,
                onToggleMode: _toggleMode,
                onGuest: widget.onAuthenticated,
              );
              if (wide) {
                return Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: _HeroPanel(entry: _entry),
                    ),
                    Expanded(
                      flex: 5,
                      child: Center(child: form),
                    ),
                  ],
                );
              }
              return SingleChildScrollView(
                child: Column(
                  children: [
                    _CompactBrand(entry: _entry),
                    form,
                    SizedBox(height: DsSpacing.x7),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HeroPanel extends StatelessWidget {
  final AnimationController entry;
  const _HeroPanel({required this.entry});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedBuilder(
      animation: entry,
      builder: (_, child) {
        final t = DsCurve.decelSoft.transform(entry.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 14),
            child: child,
          ),
        );
      },
      child: Padding(
        padding: EdgeInsets.all(DsSpacing.x10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const DsBrandMark(size: 36),
                SizedBox(width: DsSpacing.x3),
                Text('Digitorn', style: DsType.h2(color: c.textBright)),
              ],
            ),
            const Spacer(),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Text(
                'auth.welcome_title_hero'.tr(),
                style: DsType.display(size: 52, color: c.textBright),
              ),
            ),
            SizedBox(height: DsSpacing.x5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Text(
                'auth.welcome_subtitle_hero'.tr(),
                style: DsType.body(color: c.textMuted)
                    .copyWith(fontSize: 15, height: 1.6),
              ),
            ),
            const Spacer(),
            Wrap(
              spacing: DsSpacing.x3,
              runSpacing: DsSpacing.x3,
              children: [
                _FeaturePill(
                    icon: Icons.storefront_outlined,
                    label: 'auth.feat_hub'.tr()),
                _FeaturePill(
                    icon: Icons.auto_fix_high_outlined,
                    label: 'auth.feat_builder'.tr()),
                _FeaturePill(
                    icon: Icons.shield_outlined,
                    label: 'auth.feat_self_hosted_short'.tr()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FeaturePill extends StatelessWidget {
  final IconData icon;
  final String label;
  const _FeaturePill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: DsSpacing.x4,
        vertical: DsSpacing.x3,
      ),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(DsRadius.pill),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: c.accentPrimary),
          SizedBox(width: DsSpacing.x3),
          Text(label, style: DsType.caption(color: c.text)),
        ],
      ),
    );
  }
}

class _CompactBrand extends StatelessWidget {
  final AnimationController entry;
  const _CompactBrand({required this.entry});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedBuilder(
      animation: entry,
      builder: (_, child) {
        final t = DsCurve.decelSoft.transform(entry.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 10),
            child: child,
          ),
        );
      },
      child: Padding(
        padding: EdgeInsets.only(top: DsSpacing.x8, bottom: DsSpacing.x5),
        child: Column(
          children: [
            const DsBrandMark(size: 52),
            SizedBox(height: DsSpacing.x4),
            Text('Digitorn', style: DsType.h1(color: c.textBright)),
          ],
        ),
      ),
    );
  }
}

class _FormPanel extends StatelessWidget {
  final AnimationController entry;
  final _Mode mode;
  final GlobalKey<FormState> loginKey;
  final GlobalKey<FormState> registerKey;
  final TextEditingController loginUser;
  final TextEditingController loginPass;
  final TextEditingController regUser;
  final TextEditingController regEmail;
  final TextEditingController regPass;
  final TextEditingController urlCtrl;
  final bool hideLoginPass;
  final bool hideRegPass;
  final bool showAdvanced;
  final VoidCallback onToggleLoginPass;
  final VoidCallback onToggleRegPass;
  final VoidCallback onToggleAdvanced;
  final Future<void> Function() onSignIn;
  final Future<void> Function() onRegister;
  final VoidCallback onToggleMode;
  final VoidCallback onGuest;

  const _FormPanel({
    required this.entry,
    required this.mode,
    required this.loginKey,
    required this.registerKey,
    required this.loginUser,
    required this.loginPass,
    required this.regUser,
    required this.regEmail,
    required this.regPass,
    required this.urlCtrl,
    required this.hideLoginPass,
    required this.hideRegPass,
    required this.showAdvanced,
    required this.onToggleLoginPass,
    required this.onToggleRegPass,
    required this.onToggleAdvanced,
    required this.onSignIn,
    required this.onRegister,
    required this.onToggleMode,
    required this.onGuest,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSignIn = mode == _Mode.signIn;
    return AnimatedBuilder(
      animation: entry,
      builder: (_, child) {
        final t = DsCurve.decelSoft.transform(entry.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 16),
            child: child,
          ),
        );
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: DsSpacing.x6,
            vertical: DsSpacing.x7,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isSignIn
                    ? 'auth.welcome_back'.tr()
                    : 'auth.create_your_account'.tr(),
                style: DsType.display2(
                    size: 30, color: c.textBright),
              ),
              SizedBox(height: DsSpacing.x3),
              Text(
                isSignIn
                    ? 'auth.sign_in_to_continue'.tr()
                    : 'auth.set_up_account'.tr(),
                style: DsType.body(color: c.textMuted),
              ),
              SizedBox(height: DsSpacing.x8),
              AnimatedSwitcher(
                duration: DsDuration.base,
                switchInCurve: DsCurve.decelSoft,
                switchOutCurve: DsCurve.accelSoft,
                transitionBuilder: (child, anim) {
                  return FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.03),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  );
                },
                child: isSignIn
                    ? _SignInForm(
                        key: const ValueKey('signIn'),
                        formKey: loginKey,
                        user: loginUser,
                        pass: loginPass,
                        hidePass: hideLoginPass,
                        onToggleHide: onToggleLoginPass,
                        onSubmit: onSignIn,
                      )
                    : _RegisterForm(
                        key: const ValueKey('register'),
                        formKey: registerKey,
                        user: regUser,
                        email: regEmail,
                        pass: regPass,
                        hidePass: hideRegPass,
                        onToggleHide: onToggleRegPass,
                        onSubmit: onRegister,
                      ),
              ),
              SizedBox(height: DsSpacing.x4),
              const _ErrorBanner(),
              SizedBox(height: DsSpacing.x5),
              _Advanced(
                open: showAdvanced,
                urlCtrl: urlCtrl,
                onToggle: onToggleAdvanced,
              ),
              SizedBox(height: DsSpacing.x7),
              _Separator(),
              SizedBox(height: DsSpacing.x4),
              DsButton(
                label: 'auth.continue_without_account'.tr(),
                onPressed: onGuest,
                variant: DsButtonVariant.secondary,
                expand: true,
              ),
              SizedBox(height: DsSpacing.x7),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    isSignIn
                        ? 'auth.new_to_digitorn'.tr()
                        : 'auth.already_have_account'.tr(),
                    style: DsType.caption(color: c.textMuted),
                  ),
                  SizedBox(width: DsSpacing.x2),
                  DsButton(
                    label: isSignIn
                        ? 'auth.create_account'.tr()
                        : 'auth.sign_in'.tr(),
                    onPressed: onToggleMode,
                    variant: DsButtonVariant.tertiary,
                    size: DsButtonSize.sm,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignInForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController user;
  final TextEditingController pass;
  final bool hidePass;
  final VoidCallback onToggleHide;
  final Future<void> Function() onSubmit;

  const _SignInForm({
    super.key,
    required this.formKey,
    required this.user,
    required this.pass,
    required this.hidePass,
    required this.onToggleHide,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DsInput(
            controller: user,
            label: 'auth.username'.tr(),
            leadingIcon: Icons.person_outline,
            autofillHints: const [AutofillHints.username],
            textInputAction: TextInputAction.next,
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'auth.username_required'.tr()
                : null,
          ),
          SizedBox(height: DsSpacing.x4),
          DsInput(
            controller: pass,
            label: 'auth.password'.tr(),
            leadingIcon: Icons.lock_outline,
            obscureText: hidePass,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmit(),
            trailing: DsInputAction(
              icon: hidePass
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              onTap: onToggleHide,
              tooltip: hidePass
                  ? 'auth.show_password'.tr()
                  : 'auth.hide_password'.tr(),
            ),
            validator: (v) => (v == null || v.isEmpty)
                ? 'auth.password_required'.tr()
                : null,
          ),
          SizedBox(height: DsSpacing.x5),
          _LoadingAwareButton(
            label: 'auth.sign_in'.tr(),
            onPressed: onSubmit,
          ),
        ],
      ),
    );
  }
}

class _RegisterForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController user;
  final TextEditingController email;
  final TextEditingController pass;
  final bool hidePass;
  final VoidCallback onToggleHide;
  final Future<void> Function() onSubmit;

  const _RegisterForm({
    super.key,
    required this.formKey,
    required this.user,
    required this.email,
    required this.pass,
    required this.hidePass,
    required this.onToggleHide,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DsInput(
            controller: user,
            label: 'auth.username'.tr(),
            leadingIcon: Icons.person_outline,
            autofillHints: const [AutofillHints.newUsername],
            textInputAction: TextInputAction.next,
            validator: (v) => (v == null || v.trim().length < 3)
                ? 'auth.min_3_chars'.tr()
                : null,
          ),
          SizedBox(height: DsSpacing.x4),
          DsInput(
            controller: email,
            label: 'auth.email_optional'.tr(),
            leadingIcon: Icons.mail_outline,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
          ),
          SizedBox(height: DsSpacing.x4),
          DsInput(
            controller: pass,
            label: 'auth.password'.tr(),
            helper: 'auth.password_helper'.tr(),
            leadingIcon: Icons.lock_outline,
            obscureText: hidePass,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmit(),
            trailing: DsInputAction(
              icon: hidePass
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              onTap: onToggleHide,
            ),
            validator: (v) => (v == null || v.length < 12)
                ? 'auth.min_12_chars'.tr()
                : null,
          ),
          SizedBox(height: DsSpacing.x5),
          _LoadingAwareButton(
            label: 'auth.create_account'.tr(),
            onPressed: onSubmit,
          ),
        ],
      ),
    );
  }
}

class _LoadingAwareButton extends StatelessWidget {
  final String label;
  final Future<void> Function() onPressed;
  const _LoadingAwareButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthService(),
      builder: (_, _) {
        final loading = AuthService().isLoading;
        return DsButton(
          label: label,
          onPressed: loading ? null : onPressed,
          loading: loading,
          expand: true,
          size: DsButtonSize.lg,
        );
      },
    );
  }
}

class _Advanced extends StatelessWidget {
  final bool open;
  final TextEditingController urlCtrl;
  final VoidCallback onToggle;
  const _Advanced({
    required this.open,
    required this.urlCtrl,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: DsSpacing.x2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    open
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 14,
                    color: c.textMuted,
                  ),
                  SizedBox(width: DsSpacing.x1),
                  Text('common.advanced'.tr(),
                      style: DsType.caption(color: c.textMuted)),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: DsDuration.base,
          curve: DsCurve.decelSoft,
          child: open
              ? Padding(
                  padding: EdgeInsets.only(top: DsSpacing.x3),
                  child: DsInput(
                    controller: urlCtrl,
                    label: 'auth.bridge_url'.tr(),
                    leadingIcon: Icons.dns_outlined,
                    keyboardType: TextInputType.url,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _Separator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Expanded(child: Container(height: 1, color: c.border)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: DsSpacing.x4),
          child: Text('common.or'.tr(), style: DsType.micro(color: c.textDim)),
        ),
        Expanded(child: Container(height: 1, color: c.border)),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: AuthService(),
      builder: (_, _) {
        final err = AuthService().lastError;
        return AnimatedSize(
          duration: DsDuration.base,
          curve: DsCurve.decelSoft,
          alignment: Alignment.topLeft,
          child: err == null || err.isEmpty
              ? const SizedBox(width: double.infinity)
              : Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    horizontal: DsSpacing.x4,
                    vertical: DsSpacing.x3,
                  ),
                  decoration: BoxDecoration(
                    color: c.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(DsRadius.input),
                    border:
                        Border.all(color: c.red.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline, size: 14, color: c.red),
                      SizedBox(width: DsSpacing.x3),
                      Expanded(
                        child: Text(
                          err,
                          style: DsType.caption(color: c.red)
                              .copyWith(height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}
