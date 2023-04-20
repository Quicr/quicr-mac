# Cache native dependency build folders.
echo "Caching QMedia build-catalyst"
cp -r $CI_WORKSPACE/dependencies/build-catalyst $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst
echo "Caching QMedia build-catalyst-x86"
cp -r $CI_WORKSPACE/dependencies/build-catalyst-x86 $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst-x86
echo "Caching QMedia build-ios"
cp -r $CI_WORKSPACE/dependencies/build-ios $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-ios
