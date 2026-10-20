import 'dart:io';
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_service.dart';
import 'translation_service.dart';

class LLMTranslator {
  final Dio _dio = Dio();

  Future<String> translate(
    String text, {
    String? sourceLang,
    Locale? locale,
    String? sourceLanguageName,
    String? targetLanguageName,
  }) async {
    if (text.isEmpty) return text;

    try {
      final prefs = await SharedPreferences.getInstance();
      final apiUrl = prefs.getString('llm_settings_api_url') ??
          'https://api.openai.com/v1/chat/completions';
      final apiKey = prefs.getString('llm_settings_api_key') ?? '';
      final model = prefs.getString('llm_settings_model') ?? 'gpt-3.5-turbo';
      final savedPrompt = prefs.getString('llm_settings_prompt');
      final useDefaultPrompt = savedPrompt == null ||
          savedPrompt.isEmpty ||
          TranslationService.isGeneratedDefaultLLMPrompt(savedPrompt);
      final prompt = useDefaultPrompt
          ? TranslationService.getDefaultLLMPrompt(
              locale ?? const Locale('zh'),
              sourceLanguageName: sourceLanguageName,
              targetLanguageName: targetLanguageName,
            )
          : savedPrompt;

      if (apiKey.isEmpty) {
        throw StateError('LLM API key is not configured.');
      }

      final response = await _dio.post(
        apiUrl,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.json,
        ),
        data: {
          'model': model,
          'messages': [
            {'role': 'system', 'content': prompt},
            {'role': 'user', 'content': text},
          ],
          'temperature': 0.3,
        },
      );

      if (response.statusCode != 200) {
        throw HttpException('LLM returned HTTP ${response.statusCode}.');
      }

      final data = response.data;
      if (data is! Map || data['choices'] is! List || data['choices'].isEmpty) {
        throw const FormatException('Invalid LLM translation response.');
      }
      final choice = data['choices'].first;
      final message = choice is Map ? choice['message'] : null;
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        throw const FormatException('Invalid LLM translation content.');
      }
      return content.trim();
    } catch (e) {
      logOutput('LLM translation error: $e');
      if (e is DioException) {
        if (e.response != null) {
          logOutput('Response data: ${e.response?.data}');
        }
      }
      rethrow;
    }
  }
}
