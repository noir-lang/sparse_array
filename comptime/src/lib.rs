#![feature(generic_const_exprs)]

use num_bigint::{BigUint, ToBigUint};
use num_traits::Num;
use std::default::Default;
use std::str::FromStr;

pub type FieldElement = BigUint;

lazy_static::lazy_static! {
    static ref FIELD_MODULUS: FieldElement = FieldElement::from_str(
        "21888242871839275222246405745257275088696311157297823662689037894645226208583"
    ).unwrap();
}

#[derive(Debug)]
pub struct SortResult<const N: u32>
where
    [(); N as usize]: Sized,
{
    pub sorted: [FieldElement; N as usize],
    pub sort_indices: [usize; N as usize],
}

#[derive(Debug)]
pub struct SparseArray<T, const N: u32>
where
    T: std::fmt::Debug,
    [(); N as usize]: Sized,
    [(); (N + 2) as usize]: Sized,
    [(); (N + 3) as usize]: Sized,
{
    keys: [FieldElement; (N + 2) as usize],
    values: [T; (N + 3) as usize],
    maximum: FieldElement,
}

impl<T, const N: u32> SparseArray<T, N>
where
    T: Default + Clone + std::fmt::Debug,
    [(); N as usize]: Sized,
    [(); (N + 2) as usize]: Sized,
    [(); (N + 3) as usize]: Sized,
{
    pub fn create(
        keys: &[FieldElement; N as usize],
        values: [T; N as usize],
        size: FieldElement,
    ) -> Self {
        let maximum = size.clone() - FieldElement::from(1u32);

        // Create default arrays
        let mut result = SparseArray {
            keys: std::array::from_fn(|_| FieldElement::from(0u32)),
            values: vec![T::default(); (N + 3) as usize].try_into().unwrap(),
            maximum: maximum.clone(),
        };

        // Sort the keys
        let sorted = sort_advanced(keys, |a, b| a < b);

        // Insert start and endpoints
        result.keys[0] = FieldElement::from(0u32);
        for i in 0..N as usize {
            result.keys[i + 1] = sorted.sorted[i].clone();
        }
        result.keys[(N + 1) as usize] = maximum.clone();

        // Populate values based on the sorted keys
        for i in 0..N as usize {
            result.values[i + 2] = values[sorted.sort_indices[i]].clone();
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

        // Set final value (value[N+2] maps to keys[N+1] which is maximum)
        let final_value = if keys[(N - 1) as usize] == maximum {
            values[(N - 1) as usize].clone()
        } else {
            T::default()
        };
        result.values[(N + 2) as usize] = final_value;

        // Boundary checks
        assert!(
            &sorted.sorted[0] < &*FIELD_MODULUS,
            "Key exceeds field modulus"
        );
        assert!(&maximum < &*FIELD_MODULUS, "Maximum exceeds field modulus");
        assert!(
            &maximum >= &sorted.sorted[(N - 1) as usize],
            "Key exceeds maximum"
        );

        result
    }

    pub fn to_noir_string(&self, table_name: Option<&str>, generic_name: Option<&str>) -> String
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

        let table_name = table_name.unwrap_or("table");
        let generic_name = generic_name.unwrap_or("Field");

        format!(
            "let {}: SparseArray<{}, {}> = SparseArray {{\n    \
             keys: [{}],\n    \
             values: [{}],\n    \
             maximum: 0x{:08x}\n\
             }};",
            table_name, N, generic_name, keys_str, values_str, self.maximum
        )
    }

    pub fn get(&self, index: &FieldElement) -> &T {
        // If index is greater than maximum, return default value
        if index > &self.maximum {
            return &self.values[0];
        }

        let mut left = 0;
        let mut right = (N + 1) as usize;

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

fn sort_advanced<const N: u32>(
    input: &[FieldElement; N as usize],
    compare: impl Fn(&FieldElement, &FieldElement) -> bool,
) -> SortResult<N>
where
    [(); N as usize]: Sized,
{
    let mut sorted = input.clone();
    quicksort(&mut sorted, &compare);

    let sort_indices = get_shuffle_indices(input, &sorted);

    // Verify sorting
    for i in 0..(N as usize - 1) {
        assert!(
            !compare(&sorted[i + 1], &sorted[i]),
            "Array not properly sorted"
        );
    }

    SortResult {
        sorted,
        sort_indices: sort_indices.try_into().unwrap(),
    }
}

fn get_shuffle_indices<const N: u32>(
    lhs: &[FieldElement; N as usize],
    rhs: &[FieldElement; N as usize],
) -> Vec<usize> {
    let mut shuffle_indices = vec![0usize; N as usize];
    let mut shuffle_mask = vec![false; N as usize];

    for i in 0..N as usize {
        let mut found = false;
        for j in 0..N as usize {
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
        let keys = [field("1"), field("99"), field("7"), field("5")];
        let example =
            SparseArray::<i32, 4>::create(&keys, [123i32, 101112, 789, 456], field("100"));

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
        let keys = [
            field("0"),
            field("99999"),
            field("7"),
            field("4294967295"), // 0xffffffff = 2^32 - 1
        ];
        let example = SparseArray::<i32, 4>::create(
            &keys,
            [123, 101112, 789, 456],
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
        let keys = [field("1"), field("5"), field("7"), field("99999")];
        let _example = SparseArray::<i32, 4>::create(
            &keys,
            [123i32, 456, 789, 101112],
            FIELD_MODULUS.clone() + FieldElement::from(1u32),
        );
    }

    #[test]
    #[should_panic(expected = "Maximum exceeds field modulus")]
    fn test_sparse_lookup_boundary_case_overflow() {
        let keys = [
            field("0"),
            field("5"),
            field("7"),
            field("115792089237316195423570985008687907853269984665640564039457584007913129639935"),
        ];
        let _example = SparseArray::<i32, 4>::create(
            &keys,
            [123i32, 456, 789, 101112],
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
        let values = [
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
        let keys = [field("1"), field("99"), field("7"), field("5")];
        let example = SparseArray::<F, 4>::create(&keys, values.clone(), field("100000"));

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
        let keys = [
            field("0"),
            field("99999"),
            field("7"),
            field("4294967295"), // 0xffffffff
        ];
        let example = SparseArray::<u32, 4>::create(
            &keys,
            [123, 101112, 789, 456],
            field("4294967296"), // 0x100000000
        );

        let noir_str = example.to_noir_string(None, None);
        println!("\n\n===\n{}\n\n", noir_str);
        let expected = "\
            let table: SparseArray<4, Field> = SparseArray {\n    \
            keys: [0x00000000, 0x00000000, 0x00000007, 0x0001869f, 0xffffffff, 0xffffffff],\n    \
            values: [0x00000000, 0x0000007b, 0x0000007b, 0x00000315, 0x00018af8, 0x000001c8, 0x000001c8],\n    \
            maximum: 0xffffffff\n\
            };";

        assert_eq!(noir_str, expected);
    }

    // Test cases for console output
    // #[test]
    // fn print_sparse_array_10_random() {
    //     let keys = [
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
    //     let example = SparseArray::<u32, 10>::create(
    //         &keys,
    //         [700, 100, 1000, 200, 600, 400, 500, 300, 800, 900],
    //         field("0x100000"),
    //     );
    //     println!("Array size 10 (randomized):\n{}", example.to_noir_string(None, None));
    // }

    // #[test]
    // fn print_sparse_array_25_random() {
    //     let keys = [
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
    //     let values = [
    //         7777, 222, 33333, 888, 11111, 2222, 22222, 777, 77777, 8888, 44444, 111, 3333, 55555,
    //         333, 4444, 444, 66666, 555, 5555, 666, 9999, 999, 44444, 1111,
    //     ];
    //     let example = SparseArray::<u32, 25>::create(&keys, values, field("0x100000"));
    //     println!("Array size 25 (randomized):\n{}", example.to_noir_string(None, None));
    // }

    // #[test]
    // fn print_sparse_array_50_random() {
    //     let keys = [
    //         field("0x3700"),
    //         field("0x100"),
    //         field("0x2200"),
    //         field("0x4300"),
    //         field("0x1800"),
    //         field("0x3300"),
    //         field("0x900"),
    //         field("0x2800"),
    //         field("0x4400"),
    //         field("0x1400"),
    //         field("0x2F00"),
    //         field("0xE00"),
    //         field("0x2500"),
    //         field("0x3F00"),
    //         field("0x1B00"),
    //         field("0x3600"),
    //         field("0xC00"),
    //         field("0x2B00"),
    //         field("0x4000"),
    //         field("0x1700"),
    //         field("0x3200"),
    //         field("0x800"),
    //         field("0x2100"),
    //         field("0x3C00"),
    //         field("0x1300"),
    //         field("0x2D00"),
    //         field("0x400"),
    //         field("0x1900"),
    //         field("0x3800"),
    //         field("0xF00"),
    //         field("0x2600"),
    //         field("0x200"),
    //         field("0x1500"),
    //         field("0x3400"),
    //         field("0xB00"),
    //         field("0x2A00"),
    //         field("0x4100"),
    //         field("0x1600"),
    //         field("0x3100"),
    //         field("0x700"),
    //         field("0x2000"),
    //         field("0x3900"),
    //         field("0x1200"),
    //         field("0x2C00"),
    //         field("0x4200"),
    //         field("0x1A00"),
    //         field("0x3500"),
    //         field("0xD00"),
    //         field("0x2700"),
    //         field("0x3000"),
    //     ];
    //     let values = [
    //         3700, 100, 2200, 4300, 1800, 3300, 900, 2800, 4400, 1400, 2900, 1300, 2500, 3900, 1900,
    //         3600, 1200, 2700, 4000, 1700, 3200, 800, 2100, 3800, 1300, 2800, 400, 1900, 3700, 1500,
    //         2600, 200, 1500, 3400, 1100, 2600, 4100, 1600, 3100, 700, 2000, 3900, 1200, 2700, 4200,
    //         1800, 3500, 1300, 2700, 3000,
    //     ];
    //     let example = SparseArray::<u32, 50>::create(&keys, values, field("0x5000"));
    //     println!(
    //         "Array size 50 (randomized):\n{}",
    //         example.to_noir_string(None, None)
    //     );
    // }
}
