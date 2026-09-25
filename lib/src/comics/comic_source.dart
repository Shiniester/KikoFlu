import 'comic_models.dart';
import 'comic_http.dart';

abstract class ComicSource {
  ComicSource(this.http);
  final ComicHttp http;
  String get key;
  String get name;
  String get website;
  bool get hasAccount => true;
  bool get hasRemoteFavorites => true;
  bool get hasPasswordLogin => false;
  bool get hasComments => false;
  List<String> get searchSorts => const [];
  Future<ComicResult> search(String query, {String? cursor, String? sort});
  Future<ComicResult> explore({String? cursor}) => search('', cursor: cursor);
  Future<List<ComicCategory>> categories() async => const [];
  Future<ComicResult> category(ComicCategory category, {String? cursor}) =>
      search(category.id, cursor: cursor);
  Future<Comic> details(String id);
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter);
  Future<List<ComicComment>> comments(Comic comic) async => const [];
  Future<ComicResult> favorites({String? cursor}) async =>
      throw const ComicSourceException(
        'This source does not support online favorites.',
      );
  Future<void> setFavorite(Comic comic, bool value) async =>
      throw const ComicSourceException(
        'This source does not support online favorites.',
      );
  Future<void> login(String username, String password) async =>
      throw const ComicSourceException('Use the source website to sign in.');
  bool get isLoggedIn => http.hasSession;
  Future<void> logout() => http.clearSession();
}
