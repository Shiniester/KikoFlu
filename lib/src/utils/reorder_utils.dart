bool reorderByFinalIndex<T>(List<T> items, int oldIndex, int newIndex) {
  if (oldIndex < 0 || oldIndex >= items.length || items.isEmpty) return false;
  final targetIndex = newIndex.clamp(0, items.length - 1);
  if (oldIndex == targetIndex) return false;
  final item = items.removeAt(oldIndex);
  items.insert(targetIndex, item);
  return true;
}
