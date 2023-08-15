use proc_macro::TokenStream;
use quote::quote;
use syn;

#[proc_macro_attribute]
pub fn export_asm_all(_attr: TokenStream, input: TokenStream) -> TokenStream {
    let mut output_stream = input.clone();
    let ast = syn::parse_macro_input!(input as syn::DeriveInput);
    let item_ident = ast.ident;
    let item_name = item_ident.to_string();
    match &ast.data {
        syn::Data::Struct(data) => {
            assert!(matches!(data.fields, syn::Fields::Named(_)));
            for field in data.fields.iter() {
                let field_ident = field.ident.as_ref().unwrap();
                let field_name = field_ident.to_string();
                let asm_name = format!("{item_name}.{field_name}");
                let asm_expanded = quote! {
                    ::core::arch::global_asm!(
                        concat!(".global \"", #asm_name, "\"\n\"", #asm_name, "\" = {value}"),
                        value = const memoffset::offset_of!(#item_ident, #field_ident),
                    );
                };
                let asm_token_stream: proc_macro::TokenStream = asm_expanded.into();
                output_stream.extend(asm_token_stream);
            }
        }
        syn::Data::Enum(data) => {
            let mut current_value: usize = 0;
            for variant in data.variants.iter() {
                assert!(matches!(variant.fields, syn::Fields::Unit));
                let value = match variant.discriminant {
                    Some((_, ref expr)) => {
                        let syn::Expr::Lit(ref literal) = expr else {
                            panic!("enum variant discriminants must be integer literals");
                        };
                        let syn::Lit::Int(ref int_lit) = literal.lit else {
                            panic!("enum variant discriminants must be integer literals");
                        };
                        int_lit.base10_parse().unwrap()
                    }
                    None => current_value,
                };
                let variant_name = variant.ident.to_string();
                let asm_name = format!("{item_name}.{variant_name}");
                let asm_expanded = quote! {
                    ::core::arch::global_asm!(
                        concat!(".global \"", #asm_name, "\"\n\"", #asm_name, "\" = {value}"),
                        value = const #value,
                    );
                };
                let asm_token_stream: proc_macro::TokenStream = asm_expanded.into();
                output_stream.extend(asm_token_stream);
                current_value = value + 1;
            }
        }
        _ => panic!("`export_asm_all` must be called on a struct or an enum"),
    }
    output_stream
}
