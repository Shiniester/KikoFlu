#include <stddef.h>
#include <vulkan/vulkan.h>

int main(void) {
    uint32_t count = 0;
    (void)vkEnumerateInstanceExtensionProperties(NULL, &count, NULL);
    return 0;
}
