"""Independent literals, not generated-catalog self-comparison."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('catalog', Path(__file__).parents[1] / 'tools/build_hwpx_model_catalog.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class ModelCatalogTests(unittest.TestCase):
    def test_separates_classes_methods_and_ignores_comments(self):
        source = '''
        // bool CFake::WriteElement() { SetAttribute(att, L"fake", x); }
        bool COne::WriteElement() {
          Base::WriteElement(a, b, c);
          Util::CXMLAttConverter::SetAttribute(att, L"pos", n, g_PosList);
          const char* braces = "} // not a comment";
          /* SetAttribute(att, L"ignored", x); */
        }
        bool CTwo::ReadAttribute() {
          GetAttribute(att, L"count", value);
        }
        void COne::InitMap(bool) {
          OWPML_PARALIST_ADD_REDIRECT_FUNC(child, CTwo, ID_TWO);
        }
        '''
        classes = catalog.parse_classes('test.cpp', source)
        self.assertEqual(set(classes), {'COne', 'CTwo'})
        self.assertEqual(classes['COne']['writeAttributes'], [{'name': 'pos', 'enum': 'g_PosList'}])
        self.assertEqual(classes['COne']['children'], [{'element': 'child', 'class': 'CTwo', 'id': 'ID_TWO'}])
        self.assertEqual(classes['CTwo']['readAttributes'], [{'name': 'count'}])
        self.assertEqual(classes['COne']['baseCalls'], ['Base::WriteElement'])

    def test_enums_and_empty_lists(self):
        enums = catalog.parse_enums('''static const ENUMLIST g_PosList[] = {
          {A, L"TOP"}, {B, L"BOTTOM"}, {0, NULL}};
          // static const ENUMLIST g_Fake[] = {{X,L"FAKE"}};
        ''')
        self.assertEqual(enums, {'g_PosList': ['TOP', 'BOTTOM']})

    def test_unbalanced_method_fails_instead_of_silently_dropping(self):
        with self.assertRaises(ValueError):
            catalog.parse_classes('broken.cpp', 'bool COne::ReadAttribute() {')

    def test_nonliteral_attributes_are_reported(self):
        data = catalog.parse_classes('dynamic.cpp', 'bool COne::WriteElement() { SetAttribute(att, name, value); }')
        self.assertEqual(data['COne']['unresolvedAttributeCalls'], 1)

    def test_attribute_helpers_are_not_silently_omitted_or_overwritten(self):
        data = catalog.parse_classes('helpers.cpp', '''
          bool COne::WriteElement() { WriteAttribute(att); }
          bool COne::WriteAttribute() { SetAttribute(att, L"level", x); }
          bool CMargin::SetAttribute() { Util::CXMLAttConverter::SetAttribute(att, L"left", x); }
        ''')
        self.assertEqual(data['COne']['writeAttributes'], [{'name': 'level'}])
        self.assertEqual(data['CMargin']['writeAttributes'], [{'name': 'left'}])


if __name__ == '__main__':
    unittest.main()
