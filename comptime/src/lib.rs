use num_bigint::{BigUint, ToBigUint};
use num_traits::{Num};
use std::default::Default;
use std::ops::{Add, Mul, Sub};
use std::str::FromStr;

pub type FieldElement = BigUint;

lazy_static::lazy_static! {
    static ref FIELD_MODULUS: FieldElement = FieldElement::from_str(
        "21888242871839275222246405745257275088696311157297823662689037894645226208583"
    ).unwrap();
}

pub trait ToU32 {
    fn to_u32(&self) -> u32;
}

// Implement for BigUint
impl ToU32 for BigUint {
    fn to_u32(&self) -> u32 {
        self.to_u32_digits()[0]
    }
}

#[derive(Debug)]
pub struct SortResult {
    pub sorted: Vec<FieldElement>,
    pub sort_indices: Vec<usize>,
}

#[derive(Debug)]
pub struct SparseArray<T>
where
    T: std::fmt::Debug,
{
    keys: Vec<FieldElement>,
    values: Vec<T>,
    maximum: FieldElement,
}

impl<T> SparseArray<T>
where
    T: Default
        + Clone
        + std::fmt::Debug
        + From<u32>
        + ToU32
        + Add<Output = T>
        + Sub<Output = T>
        + Mul<Output = T>
        + PartialEq
        + PartialOrd,
{
    pub fn create(keys: &[FieldElement], values: &[T], size: FieldElement) -> Self {
        let n = keys.len();
        println!("Key length: {}", n);
        assert_eq!(n, values.len(), "Keys and values must have the same length");

        let maximum = size.clone() - FieldElement::from(1u32);

        // Create vectors with capacity for n+2 keys and n+3 values
        let mut result = SparseArray {
            keys: Vec::with_capacity(n + 2),
            values: vec![T::default(); n + 3],
            maximum: maximum.clone(),
        };

        // Sort the keys
        let sorted = sort_advanced(keys);

        // Insert start and endpoints
        result.keys.push(FieldElement::from(0u32));
        result.keys.extend(sorted.sorted.iter().cloned());
        result.keys.push(maximum.clone());

        // Populate values based on the sorted keys
        for i in 0..n {
            result.values[sorted.sort_indices[i] + 2] = values[i].clone();
        }

        // Handle initial and final values
        result.values[0] = T::default(); // default value for non-existent keys

        // Set initial value (value[1] maps to keys[0] which is 0)
        let initial_value = if keys[0] == FieldElement::from(0u32) {
            values[0].clone()
        } else {
            T::default()
        };
        result.values[1] = initial_value;

        // Set final value (value[n+2] maps to keys[n+1] which is maximum)
        let final_value = if keys[n - 1] == maximum {
            values[n - 1].clone()
        } else {
            T::default()
        };
        result.values[n + 2] = final_value;

        // Boundary checks
        assert!(
            &sorted.sorted[0] < &*FIELD_MODULUS,
            "Key exceeds field modulus"
        );
        assert!(&maximum < &*FIELD_MODULUS, "Maximum exceeds field modulus");
        assert!(&maximum >= &sorted.sorted[n - 1], "Key exceeds maximum");

        result
    }

    pub fn create_packed(table: &[T], max_size: u32) -> Self {
        let mut small_keys = Vec::new();
        let mut small_values = Vec::new();
        let mut keys = Vec::new();
        let mut values = Vec::new();

        // Find max value and collect non-zero entries
        let mut max_value = T::default();
        for i in 0..table.len() {
            // Convert to u32 for comparison
            if &table[i] > &max_value {
                max_value = table[i].clone();
            }

            if table[i] != T::from(0) {
                keys.push(FieldElement::from(i as u32));
                values.push(table[i].clone());

                if i < 256 {
                    small_keys.push(FieldElement::from(i as u32));
                    small_values.push(table[i].clone());
                }
            }
        }

        // Combine values according to the dual encoding scheme
        for i in 0..small_keys.len() {
            let target_value = small_values[i].clone() * T::from(256);

            // Use the full max_value range exactly like the original
            for j in 0..max_value.to_u32() {
                let target_key =
                    FieldElement::from(j) * FieldElement::from(256u32) + small_keys[i].clone();
                let mut found_key = false;

                for k in 0..keys.len() {
                    if keys[k] == target_key {
                        values[k] = values[k].clone() + target_value.clone();
                        found_key = true;
                        break;
                    }
                }

                if !found_key {
                    keys.push(target_key);
                    values.push(target_value.clone());
                }
            }
        }

        // Print the number of entries for debugging
        let num_entries = keys.len();
        println!("Number of entries: {}", num_entries);

        // Create the SparseArray using the create method
        Self::create(&keys, &values, FieldElement::from(max_size))
    }

    pub fn to_noir_string(&self, generic_name: Option<&str>) -> String
    where
        T: ToString,
    {
        let keys_str = self
            .keys
            .iter()
            .map(|k| format!("0x{:08x}", k))
            .collect::<Vec<_>>()
            .join(", ");

        let values_str = self
            .values
            .iter()
            .map(|v| format!("0x{:08x}", v.to_string().parse::<u32>().unwrap()))
            .collect::<Vec<_>>()
            .join(", ");

        let generic_name = generic_name.unwrap_or("Field");
        let table_length: usize = self.keys.len() - 2;

        format!(
            "SparseArray<{}, {}> = SparseArray {{\n    \
             keys: [{}],\n    \
             values: [{}],\n    \
             maximum: 0x{:08x}\n\
             }};",
            table_length, generic_name, keys_str, values_str, self.maximum
        )
    }

    pub fn get(&self, index: &FieldElement) -> &T {
        // If index is greater than maximum, return default value
        if index > &self.maximum {
            return &self.values[0];
        }

        let mut left = 0;
        let mut right = self.keys.len() - 1;

        while left + 1 < right {
            let mid = (left + right) / 2;
            if &self.keys[mid] <= index {
                left = mid;
            } else {
                right = mid;
            }
        }

        // Found the interval [left, right) that contains index
        // Check if index exactly matches the left boundary
        if &self.keys[left] == index {
            &self.values[left + 1]
        } else {
            // If not an exact match, return default value
            &self.values[0]
        }
    }

    pub fn get_maximum(&self) -> &FieldElement {
        &self.maximum
    }
}

fn sort_advanced(input: &[FieldElement]) -> SortResult {
    let mut sorted = input.to_vec();
    quicksort(&mut sorted, &|a, b| a < b);

    let sort_indices = get_shuffle_indices(input, &sorted);

    // Verify sorting
    for i in 0..(sorted.len() - 1) {
        assert!(!(&sorted[i + 1] < &sorted[i]), "Array not properly sorted");
    }

    SortResult {
        sorted,
        sort_indices,
    }
}

fn get_shuffle_indices(lhs: &[FieldElement], rhs: &[FieldElement]) -> Vec<usize> {
    let n = lhs.len();
    let mut shuffle_indices = vec![0usize; n];
    let mut shuffle_mask = vec![false; n];

    for i in 0..n {
        let mut found = false;
        for j in 0..n {
            if !shuffle_mask[j] && !found && lhs[i] == rhs[j] {
                found = true;
                shuffle_indices[i] = j;
                shuffle_mask[j] = true;
            }
        }
        assert!(found, "Arrays do not contain equivalent values");
    }

    shuffle_indices
}

// Keeping the existing partition and quicksort functions as they already work with slices
fn partition<T>(
    arr: &mut [T],
    low: usize,
    high: usize,
    compare: &impl Fn(&T, &T) -> bool,
) -> usize {
    let pivot = high;
    let mut i = low;

    for j in low..high {
        if compare(&arr[j], &arr[pivot]) {
            arr.swap(i, j);
            i += 1;
        }
    }
    arr.swap(i, pivot);
    i
}

fn quicksort_recursive<T>(
    arr: &mut [T],
    low: usize,
    high: usize,
    compare: &impl Fn(&T, &T) -> bool,
) {
    if low < high {
        let pivot_index = partition(arr, low, high, compare);
        if pivot_index > 0 {
            quicksort_recursive(arr, low, pivot_index - 1, compare);
        }
        if pivot_index < high {
            quicksort_recursive(arr, pivot_index + 1, high, compare);
        }
    }
}

fn quicksort<T>(arr: &mut [T], compare: &impl Fn(&T, &T) -> bool) {
    if arr.len() > 1 {
        quicksort_recursive(arr, 0, arr.len() - 1, compare);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field(s: &str) -> FieldElement {
        match s.starts_with("0x") {
            true => FieldElement::from_str_radix(&s[2..], 16).unwrap(),
            false => FieldElement::from_str(s).unwrap(),
        }
    }

    #[test]
    fn test_sparse_lookup() {
        let keys = vec![field("1"), field("99"), field("7"), field("5")];
        let values = vec![123i32, 101112, 789, 456];
        let example = SparseArray::create(&keys, &values, field("100"));

        // Test exact matches
        assert_eq!(*example.get(&field("1")), 123);
        assert_eq!(*example.get(&field("5")), 456);
        assert_eq!(*example.get(&field("7")), 789);
        assert_eq!(*example.get(&field("99")), 101112);

        // Test values between keys
        assert_eq!(*example.get(&field("0")), 0);
        assert_eq!(*example.get(&field("2")), 0);
        assert_eq!(*example.get(&field("6")), 0);
        assert_eq!(*example.get(&field("8")), 0);
        assert_eq!(*example.get(&field("98")), 0);

        // Test all values systematically
        for i in 0u32..100 {
            let i_field = FieldElement::from(i);
            if i_field != field("1")
                && i_field != field("5")
                && i_field != field("7")
                && i_field != field("99")
            {
                assert_eq!(*example.get(&i_field), 0);
            }
        }
    }

    #[test]
    fn test_sparse_lookup_boundary_cases() {
        // what about when keys[0] = 0 and keys[N-1] = 2^32 - 1?
        let keys = vec![
            field("0"),
            field("99999"),
            field("7"),
            field("4294967295"), // 0xffffffff = 2^32 - 1
        ];
        let values = vec![123, 101112, 789, 456];
        let example = SparseArray::create(
            &keys,
            &values,
            field("4294967296"), // 0x100000000 = 2^32
        );

        assert_eq!(*example.get(&field("0")), 123);
        assert_eq!(*example.get(&field("99999")), 101112);
        assert_eq!(*example.get(&field("7")), 789);
        assert_eq!(*example.get(&field("4294967295")), 456); // 0xffffffff
        assert_eq!(*example.get(&field("4294967294")), 0); // 0xfffffffe
    }

    #[test]
    #[should_panic(expected = "Maximum exceeds field modulus")]
    fn test_sparse_lookup_overflow() {
        let keys = vec![field("1"), field("5"), field("7"), field("99999")];
        let values = vec![123i32, 456, 789, 101112];
        let _example = SparseArray::create(
            &keys,
            &values,
            FIELD_MODULUS.clone() + FieldElement::from(1u32),
        );
    }

    #[test]
    #[should_panic(expected = "Maximum exceeds field modulus")]
    fn test_sparse_lookup_boundary_case_overflow() {
        let keys = vec![
            field("0"),
            field("5"),
            field("7"),
            field("115792089237316195423570985008687907853269984665640564039457584007913129639935"),
        ];
        let values = vec![123i32, 456, 789, 101112];
        let _example = SparseArray::create(
            &keys,
            &values,
            FIELD_MODULUS.clone() + FieldElement::from(1u32),
        );
    }

    #[derive(Debug, Clone, PartialEq)]
    struct F {
        foo: [FieldElement; 3],
    }

    impl Default for F {
        fn default() -> Self {
            F {
                foo: std::array::from_fn(|_| FieldElement::from(0u32)),
            }
        }
    }

    #[test]
    fn test_sparse_lookup_struct() {
        let values = vec![
            F {
                foo: [field("1"), field("2"), field("3")],
            },
            F {
                foo: [field("4"), field("5"), field("6")],
            },
            F {
                foo: [field("7"), field("8"), field("9")],
            },
            F {
                foo: [field("10"), field("11"), field("12")],
            },
        ];
        let keys = vec![field("1"), field("99"), field("7"), field("5")];
        let example = SparseArray::create(&keys, &values, field("100000"));

        assert_eq!(*example.get(&field("1")), values[0]);
        assert_eq!(*example.get(&field("5")), values[3]);
        assert_eq!(*example.get(&field("7")), values[2]);
        assert_eq!(*example.get(&field("99")), values[1]);

        for i in 0u32..100 {
            let i_field = FieldElement::from(i);
            if i_field != field("1")
                && i_field != field("5")
                && i_field != field("7")
                && i_field != field("99")
            {
                assert_eq!(*example.get(&i_field), F::default());
            }
        }
    }

    #[test]
    fn test_sparse_array_noir_representation() {
        let keys = vec![
            field("0"),
            field("99999"),
            field("7"),
            field("4294967295"), // 0xffffffff
        ];
        let values = vec![123, 101112, 789, 456];
        let example = SparseArray::create(
            &keys,
            &values,
            field("4294967296"), // 0x100000000
        );

        let noir_str = example.to_noir_string(None);
        println!("\n\n===\n{}\n\n", noir_str);
        let expected = "\
            sparse_array::SparseArray<Field, 4> = sparse_array::SparseArray {\n    \
            keys: [0x00000000, 0x00000000, 0x00000007, 0x0001869f, 0xffffffff, 0xffffffff],\n    \
            values: [0x00000000, 0x0000007b, 0x0000007b, 0x00000315, 0x00018af8, 0x000001c8, 0x000001c8],\n    \
            maximum: 0xffffffff\n\
            };";

        assert_eq!(noir_str, expected);
    }

    // Test cases for console output
    // #[test]
    // fn print_sparse_array_10_random() {
    //     let keys = vec![
    //         field("0x33333"),
    //         field("0x1234"),
    //         field("0xFFFFF"),
    //         field("0x5678"),
    //         field("0x22222"),
    //         field("0xDEF0"),
    //         field("0x11111"),
    //         field("0x9ABC"),
    //         field("0x44444"),
    //         field("0x55555"),
    //     ];

    //     let values = vec![700, 100, 1000, 200, 600, 400, 500, 300, 800, 900];
    //     let example = SparseArray::create(&keys, &values, field("0x100000"));
    //     println!(
    //         "Array size 10 (randomized):\n{}",
    //         example.to_noir_string(None)
    //     );
    // }

    // #[test]
    // fn print_sparse_array_25_random() {
    //     let keys = vec![
    //         field("0xE000"),
    //         field("0x1000"),
    //         field("0x50000"),
    //         field("0x8000"),
    //         field("0x20000"),
    //         field("0xA000"),
    //         field("0x30000"),
    //         field("0x6000"),
    //         field("0x90000"),
    //         field("0xF000"),
    //         field("0x40000"),
    //         field("0x100"),
    //         field("0xB000"),
    //         field("0x70000"),
    //         field("0x2000"),
    //         field("0xC000"),
    //         field("0x3000"),
    //         field("0x80000"),
    //         field("0x4000"),
    //         field("0xD000"),
    //         field("0x5000"),
    //         field("0x10000"),
    //         field("0x7000"),
    //         field("0x60000"),
    //         field("0x9000"),
    //     ];
    //     let values = vec![
    //         7777, 222, 33333, 888, 11111, 2222, 22222, 777, 77777, 8888, 44444, 111, 3333, 55555,
    //         333, 4444, 444, 66666, 555, 5555, 666, 9999, 999, 44444, 1111,
    //     ];
    //     let example = SparseArray::create(&keys, &values, field("0x100000"));
    //     println!(
    //         "Array size 25 (randomized):\n{}",
    //         example.to_noir_string(None)
    //     );
    // }

    #[test]
    fn print_sparse_array_50_random() {
        let keys = vec![
            field("0x3700"),
            field("0x100"),
            field("0x2200"),
            field("0x4300"),
            field("0x1800"),
            field("0x3300"),
            field("0x900"),
            field("0x2800"),
            field("0x4400"),
            field("0x1400"),
            field("0x2F00"),
            field("0xE00"),
            field("0x2500"),
            field("0x3F00"),
            field("0x1B00"),
            field("0x3600"),
            field("0xC00"),
            field("0x2B00"),
            field("0x4000"),
            field("0x1700"),
            field("0x3200"),
            field("0x800"),
            field("0x2100"),
            field("0x3C00"),
            field("0x1300"),
            field("0x2D00"),
            field("0x400"),
            field("0x1900"),
            field("0x3800"),
            field("0xF00"),
            field("0x2600"),
            field("0x200"),
            field("0x1500"),
            field("0x3400"),
            field("0xB00"),
            field("0x2A00"),
            field("0x4100"),
            field("0x1600"),
            field("0x3100"),
            field("0x700"),
            field("0x2000"),
            field("0x3900"),
            field("0x1200"),
            field("0x2C00"),
            field("0x4200"),
            field("0x1A00"),
            field("0x3500"),
            field("0xD00"),
            field("0x2700"),
            field("0x3000"),
        ];
        let values = vec![
            field("3700"),
            field("100"),
            field("2200"),
            field("4300"),
            field("1800"),
            field("3300"),
            field("900"),
            field("2800"),
            field("4400"),
            field("1400"),
            field("2900"),
            field("1300"),
            field("2500"),
            field("3900"),
            field("1900"),
            field("3600"),
            field("1200"),
            field("2700"),
            field("4000"),
            field("1700"),
            field("3200"),
            field("800"),
            field("2100"),
            field("3800"),
            field("1300"),
            field("2800"),
            field("400"),
            field("1900"),
            field("3700"),
            field("1500"),
            field("2600"),
            field("200"),
            field("1500"),
            field("3400"),
            field("1100"),
            field("2600"),
            field("4100"),
            field("1600"),
            field("3100"),
            field("700"),
            field("2000"),
            field("3900"),
            field("1200"),
            field("2700"),
            field("4200"),
            field("1800"),
            field("3500"),
            field("1300"),
            field("2700"),
            field("3000"),
        ];
        let example = SparseArray::create(&keys, &values, field("0x5000"));
        println!(
            "Array size 50 (randomized):\n{}",
            example.to_noir_string(None)
        );
    }
}
