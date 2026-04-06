import 'package:digitorn_client/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/auth_service.dart';

class LoginPage extends StatefulWidget {
  final VoidCallback onAuthenticated;

  const LoginPage({super.key, required this.onAuthenticated});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _loginForm = GlobalKey<FormState>();
  final _registerForm = GlobalKey<FormState>();

  // Login fields
  final _loginUser = TextEditingController();
  final _loginPass = TextEditingController();

  // Register fields
  final _regUser = TextEditingController();
  final _regPass = TextEditingController();
  final _regEmail = TextEditingController();
  final _regDisplay = TextEditingController();

  // Server URL
  final _urlCtrl = TextEditingController(text: 'http://127.0.0.1:8000');

  bool _obscurePass = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _urlCtrl.text = AuthService().baseUrl;
  }

  @override
  void dispose() {
    _tabs.dispose();
    _loginUser.dispose();
    _loginPass.dispose();
    _regUser.dispose();
    _regPass.dispose();
    _regEmail.dispose();
    _regDisplay.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _doLogin() async {
    if (!_loginForm.currentState!.validate()) return;
    AuthService().baseUrl = _urlCtrl.text.trim();
    final ok = await AuthService().login(
      username: _loginUser.text.trim(),
      password: _loginPass.text,
    );
    if (ok && mounted) widget.onAuthenticated();
  }

  Future<void> _doRegister() async {
    if (!_registerForm.currentState!.validate()) return;
    AuthService().baseUrl = _urlCtrl.text.trim();
    final ok = await AuthService().register(
      username: _regUser.text.trim(),
      password: _regPass.text,
      email: _regEmail.text.trim().isEmpty ? null : _regEmail.text.trim(),
      displayName:
          _regDisplay.text.trim().isEmpty ? null : _regDisplay.text.trim(),
    );
    if (ok && mounted) widget.onAuthenticated();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: context.colors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.colors.borderHover),
                ),
                child: Icon(Icons.hub_outlined, color: context.colors.textMuted, size: 24),
              ),
              const SizedBox(height: 20),
              Text('Digitorn Console',
                  style: GoogleFonts.inter(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: context.colors.textBright)),
              const SizedBox(height: 6),
              Text('Connect to your Digitorn Bridge daemon',
                  style: GoogleFonts.inter(
                      fontSize: 13, color: context.colors.textMuted)),
              const SizedBox(height: 32),

              // Card
              Container(
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: context.colors.border),
                ),
                child: Column(
                  children: [
                    // Tabs
                    Container(
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: context.colors.border)),
                      ),
                      child: TabBar(
                        controller: _tabs,
                        labelStyle: GoogleFonts.inter(
                            fontSize: 13, fontWeight: FontWeight.w600),
                        unselectedLabelStyle:
                            GoogleFonts.inter(fontSize: 13),
                        labelColor: context.colors.textBright,
                        unselectedLabelColor: context.colors.textMuted,
                        indicatorColor: context.colors.text,
                        indicatorWeight: 1.5,
                        dividerColor: Colors.transparent,
                        tabs: const [
                          Tab(text: 'Sign in'),
                          Tab(text: 'Register'),
                        ],
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          // Server URL always visible
                          _DarkField(
                            controller: _urlCtrl,
                            label: 'Daemon URL',
                            hint: 'http://127.0.0.1:8000',
                            prefixIcon: Icons.dns_outlined,
                          ),
                          const SizedBox(height: 16),

                          // Tabs content
                          SizedBox(
                            height: 220,
                            child: TabBarView(
                              controller: _tabs,
                              children: [
                                _buildLoginForm(),
                                _buildRegisterForm(),
                              ],
                            ),
                          ),

                          // Error message
                          ListenableBuilder(
                            listenable: AuthService(),
                            builder: (_, __) {
                              final err = AuthService().lastError;
                              if (err == null) return const SizedBox.shrink();
                              return Container(
                                margin: const EdgeInsets.only(top: 12),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: context.colors.surfaceAlt,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color: context.colors.red),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.error_outline,
                                        color: context.colors.red, size: 14),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(err,
                                          style: GoogleFonts.inter(
                                              fontSize: 12,
                                              color: context.colors.red)),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
              _GuestButton(onTap: widget.onAuthenticated),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoginForm() {
    return Form(
      key: _loginForm,
      child: Column(
        children: [
          _DarkField(
            controller: _loginUser,
            label: 'Username',
            hint: 'your-username',
            prefixIcon: Icons.person_outline,
            validator: (v) => v!.isEmpty ? 'Required' : null,
          ),
          const SizedBox(height: 12),
          _DarkField(
            controller: _loginPass,
            label: 'Password',
            hint: '••••••••••••',
            prefixIcon: Icons.lock_outline,
            obscureText: _obscurePass,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                size: 16, color: context.colors.textMuted,
              ),
              onPressed: () => setState(() => _obscurePass = !_obscurePass),
            ),
            validator: (v) => v!.isEmpty ? 'Required' : null,
          ),
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: AuthService(),
            builder: (_, __) => _PrimaryButton(
              label: 'Sign in',
              isLoading: AuthService().isLoading,
              onPressed: _doLogin,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRegisterForm() {
    return Form(
      key: _registerForm,
      child: SingleChildScrollView(
        child: Column(
          children: [
            _DarkField(
              controller: _regUser,
              label: 'Username',
              hint: 'your-username',
              prefixIcon: Icons.person_outline,
              validator: (v) =>
                  v!.length < 3 ? 'Min. 3 characters' : null,
            ),
            const SizedBox(height: 10),
            _DarkField(
              controller: _regPass,
              label: 'Password',
              hint: '••••••••••••',
              prefixIcon: Icons.lock_outline,
              obscureText: true,
              validator: (v) =>
                  v!.length < 12 ? 'Min. 12 characters' : null,
            ),
            const SizedBox(height: 10),
            _DarkField(
              controller: _regEmail,
              label: 'Email (optional)',
              hint: 'you@example.com',
              prefixIcon: Icons.mail_outline,
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: AuthService(),
              builder: (_, __) => _PrimaryButton(
                label: 'Create account',
                isLoading: AuthService().isLoading,
                onPressed: _doRegister,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuestButton extends StatefulWidget {
  final VoidCallback onTap;
  const _GuestButton({required this.onTap});

  @override
  State<_GuestButton> createState() => _GuestButtonState();
}

class _GuestButtonState extends State<_GuestButton> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          'Continue without account',
          style: GoogleFonts.inter(
            fontSize: 13,
            color: _h ? context.colors.textMuted : context.colors.textMuted,
            decoration: TextDecoration.underline,
            decorationColor: _h ? context.colors.textMuted : context.colors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _DarkField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData prefixIcon;
  final bool obscureText;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;

  const _DarkField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.prefixIcon,
    this.obscureText = false,
    this.suffixIcon,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      validator: validator,
      style: GoogleFonts.inter(fontSize: 13, color: context.colors.textBright),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: GoogleFonts.inter(fontSize: 12, color: context.colors.textMuted),
        hintStyle: GoogleFonts.inter(fontSize: 13, color: context.colors.borderHover),
        prefixIcon: Icon(prefixIcon, size: 16, color: context.colors.textMuted),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: context.colors.bg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.colors.borderHover),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.colors.borderHover),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.colors.red),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.colors.red),
        ),
        errorStyle: GoogleFonts.inter(fontSize: 11, color: context.colors.red),
      ),
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  final String label;
  final bool isLoading;
  final VoidCallback onPressed;

  const _PrimaryButton({
    required this.label,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.isLoading ? null : widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: double.infinity,
          height: 40,
          decoration: BoxDecoration(
            color: _h ? context.colors.borderHover : context.colors.border,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.colors.borderHover),
          ),
          child: Center(
            child: widget.isLoading
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: context.colors.textMuted),
                  )
                : Text(
                    widget.label,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.colors.textBright,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
