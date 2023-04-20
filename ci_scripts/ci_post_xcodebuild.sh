# Cache native dependency build folders.
mv $CI_WORKSPACE/dependencies/build-catalyst $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst
mv $CI_WORKSPACE/dependencies/build-catalyst-x86 $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst-x86
mv $CI_WORKSPACE/dependencies/build-ios $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-ios
