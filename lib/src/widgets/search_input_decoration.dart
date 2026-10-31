import 'package:flutter/material.dart';

InputDecoration searchInputDecoration({
  required String hintText,
  Widget? suffixIcon,
  String? prefixText,
}) => InputDecoration(
  hintText: hintText,
  prefixIcon: const Icon(Icons.search),
  prefixText: prefixText,
  suffixIcon: suffixIcon,
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
);
