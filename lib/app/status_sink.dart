/// Where features report what the user should see: one error and one notice.
/// The app controller implements it, so features need not know about it.
abstract interface class StatusSink {
  String? get error;
  set error(String? value);
  String? get notice;
  set notice(String? value);

  /// Tells listeners the error or notice changed.
  void changed();
}
