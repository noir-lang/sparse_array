mod mut_sparse_array;
use dep::sort::sort_advanced;

unconstrained fn __sort_field_as_u32(lhs: Field, rhs: Field) -> bool {
    //  lhs.lt(rhs)
    lhs as u32 < rhs as u32
}

fn assert_sorted(lhs: Field, rhs: Field) {
    let result = (rhs - lhs - 1);
    result.assert_max_bit_size::<32>();
}

/**
 * @brief MutSparseArray, a sparse array of configurable size with `N` nonzero entries.
 *        Can be read from and written into
 *
 * @param keys is size N+2 because we want to always ensure that,
 *        for any valid index, there is some X where `keys[X] <= index <= keys[X+1]`
 *        when constructing, we will set keys[0] = 0, and keys[N-1] = maximum - 1
 * @param values is size N+3 because of the following:
 *        1. keys[i] maps to values[i+1]
 *        2. values[0] is an empty object. when calling `get(idx)`, if `idx` is not in `keys` we will return `values[0]`
 **/
struct MutSparseArrayBase<let N: u32, T, ComparisonFuncs> {
    values: [T; N + 3],
    keys: [Field; N + 2],
    linked_keys: [Field; N + 2],
    tail_ptr: Field,
    maximum: Field,
}

struct U32RangeTraits {}

pub struct MutSparseArray<let N: u32, T> {
    inner: MutSparseArrayBase<N, T, U32RangeTraits>,
}
/**
 * @brief SparseArray, stores a sparse array of up to size 2^32 with `N` nonzero entries
 *        SparseArray is constant i.e. values canot be inserted after creation.
 *        See MutSparseArray for a mutable version (a bit more expensive)
 * @param keys is size N+2 because we want to always ensure that,
 *        for any valid index, there is some X where `keys[X] <= index <= keys[X+1]`
 *        when constructing, we will set keys[0] = 0, and keys[N-1] = maximum - 1
 * @param values is size N+3 because of the following:
 *        1. keys[i] maps to values[i+1]
 *        2. values[0] is an empty object. when calling `get(idx)`, if `idx` is not in `keys` we will return `values[0]`
 **/
pub struct SparseArray<let N: u32, T> {
    keys: [Field; N + 2],
    values: [T; N + 3],
    maximum: Field, // can be up to 2^32
}
impl<let N: u32, T> SparseArray<N, T>
where
    T: std::default::Default,
{

    /**
     * @brief construct a SparseArray
     **/
    fn create(_keys: [Field; N], _values: [T; N], size: Field) -> Self {
        let _maximum = size - 1;
        let mut r: Self =
            SparseArray { keys: [0; N + 2], values: [T::default(); N + 3], maximum: _maximum };

        // for any valid index, we want to ensure the following is satified:
        // self.keys[X] <= index <= self.keys[X+1]
        // this requires us to sort hte keys, and insert a startpoint and endpoint
        let sorted_keys = sort_advanced(_keys, __sort_field_as_u32, assert_sorted);

        // insert start and endpoints
        r.keys[0] = 0;
        for i in 0..N {
            r.keys[i + 1] = sorted_keys.sorted[i];
        }
        r.keys[N + 1] = _maximum;

        // populate values based on the sorted keys
        // note: self.keys[i] maps to self.values[i+1]
        // self.values[0] does not map to any key. we use it to store the default empty value,
        // which is returned when `get(idx)` is called and `idx` does not exist in `self.keys`
        for i in 0..N {
            r.values[i + 2] = _values[sorted_keys.sort_indices[i]];
        }
        // insert values that map to our key start and endpoints
        // if _keys[0] = 0 then values[0] must equal _values[0], so some conditional logic is required
        // (same for _keys[N-1])
        let mut initial_value = T::default();
        if (_keys[0] == 0) {
            initial_value = _values[0];
        }
        let mut final_value = T::default();
        if (_keys[N - 1] == _maximum) {
            final_value = _values[N - 1];
        }
        r.values[1] = initial_value;
        r.values[N + 2] = final_value;

        // perform boundary checks!
        // the maximum size of the sparse array is 2^32
        // we need to check that every element in `self.keys` is less than 2^32
        // because `self.keys` is sorted, we can simply validate that
        // sorted_keys.sorted[0] < 2^32
        // sorted_keys.sorted[N-1] < maximum
        sorted_keys.sorted[0].assert_max_bit_size::<32>();
        _maximum.assert_max_bit_size::<32>();
        (_maximum - sorted_keys.sorted[N - 1]).assert_max_bit_size::<32>();
        r
    }

    /**
     * @brief determine whether `target` is present in `self.keys`
     * @details if `found == false`, `self.keys[found_index] < target < self.keys[found_index + 1]`
     **/
    unconstrained fn search_for_key(self, target: Field) -> (Field, Field) {
        let mut found = false;
        let mut found_index = 0;
        let mut previous_less_than_or_equal_to_target = false;
        for i in 0..N + 2 {
            // if target = 0xffffffff we need to be able to add 1 here, so use u64
            let current_less_than_or_equal_to_target = self.keys[i] as u64 <= target as u64;
            if (self.keys[i] == target) {
                found = true;
                found_index = i as Field;
                break;
            }
            if (previous_less_than_or_equal_to_target & !current_less_than_or_equal_to_target) {
                found_index = i as Field - 1;
                break;
            }
            previous_less_than_or_equal_to_target = current_less_than_or_equal_to_target;
        }
        (found as Field, found_index)
    }

    /**
     * @brief return element `idx` from the sparse array
     * @details cost is 14.5 gates per lookup
     **/
    fn get(self, idx: Field) -> T {
        let (found, found_index) = unsafe { self.search_for_key(idx) };
        // bool check. 0.25 gates cheaper than a raw `bool` type. need to fix at some point
        assert(found * found == found);

        // OK! So we have the following cases to check
        // 1. if `found` then `self.keys[found_index] == idx`
        // 2. if `!found` then `self.keys[found_index] < idx < self.keys[found_index + 1]
        // how do we simplify these checks?
        // case 1 can be converted to `self.keys[found_index] <= idx <= self.keys[found_index]
        // case 2 can be modified to  `self.keys[found_index] + 1 <= idx <= self.keys[found_index + 1] - 1
        // combine the two into the following single statement:
        // `self.keys[found_index] + 1 - found <= idx <= self.keys[found_index + 1 - found] - 1 + found
        let lhs = self.keys[found_index];
        let rhs = self.keys[found_index + 1 - found];
        let lhs_condition = idx - lhs - 1 + found;
        let rhs_condition = rhs - 1 + found - idx;
        lhs_condition.assert_max_bit_size::<32>();
        rhs_condition.assert_max_bit_size::<32>();

        // self.keys[i] maps to self.values[i+1]
        // however...if we did not find a non-sparse entry, we want to return self.values[0] (the default value)
        let value_index = (found_index + 1) * found;
        self.values[value_index]
    }
}

mod test {

    use crate::SparseArray;
    #[test]
    fn test_sparse_lookup() {
        let example = SparseArray::create([1, 99, 7, 5], [123, 101112, 789, 456], 100);

        assert(example.get(1) == 123);
        assert(example.get(5) == 456);
        assert(example.get(7) == 789);
        assert(example.get(99) == 101112);

        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i as Field) == 0);
            }
        }
    }

    #[test]
    fn test_2() {
        let keys = [0, 99999, 7, 4294967295];
        let values = [123, 101112, 789, 456];
        let example = SparseArray::create(keys, values, 0x100000000);
        println(example);
    }

    #[test]
    fn test_sparse_lookup_boundary_cases() {
        // what about when keys[0] = 0 and keys[N-1] = 2^32 - 1?
        let example = SparseArray::create(
            [0, 99999, 7, 0xffffffff],
            [123, 101112, 789, 456],
            0x100000000,
        );

        println("keys");
        println(example.keys);

        assert(example.get(0) == 123);
        assert(example.get(99999) == 101112);
        assert(example.get(7) == 789);
        assert(example.get(0xffffffff) == 456);
        assert(example.get(0xfffffffe) == 0);
    }

    #[test(should_fail_with = "call to assert_max_bit_size")]
    fn test_sparse_lookup_overflow() {
        let example = SparseArray::create([1, 5, 7, 99999], [123, 456, 789, 101112], 100000);

        assert(example.get(100000) == 0);
    }

    #[test(should_fail_with = "call to assert_max_bit_size")]
    fn test_sparse_lookup_boundary_case_overflow() {
        let example =
            SparseArray::create([0, 5, 7, 0xffffffff], [123, 456, 789, 101112], 0x100000000);

        assert(example.get(0x100000000) == 0);
    }

    #[test(should_fail_with = "call to assert_max_bit_size")]
    fn test_sparse_lookup_key_exceeds_maximum() {
        let example =
            SparseArray::create([0, 5, 7, 0xffffffff], [123, 456, 789, 101112], 0xffffffff);
        assert(example.maximum == 0xffffffff);
    }
    #[test]
    fn test_sparse_lookup_u32() {
        let example = SparseArray::create(
            [1, 99, 7, 5],
            [123 as u32, 101112 as u32, 789 as u32, 456 as u32],
            100,
        );

        assert(example.get(1) == 123);
        assert(example.get(5) == 456);
        assert(example.get(7) == 789);
        assert(example.get(99) == 101112);

        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i as Field) == 0);
            }
        }
    }

    struct F {
        foo: [Field; 3],
    }
    impl std::cmp::Eq for F {
        fn eq(self, other: Self) -> bool {
            self.foo == other.foo
        }
    }

    impl std::default::Default for F {
        fn default() -> Self {
            F { foo: [0; 3] }
        }
    }

    #[test]
    fn test_sparse_lookup_struct() {
        let values = [
            F { foo: [1, 2, 3] },
            F { foo: [4, 5, 6] },
            F { foo: [7, 8, 9] },
            F { foo: [10, 11, 12] },
        ];
        let example = SparseArray::create([1, 99, 7, 5], values, 100000);

        assert(example.get(1) == values[0]);
        assert(example.get(5) == values[3]);
        assert(example.get(7) == values[2]);
        assert(example.get(99) == values[1]);
        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i as Field) == F::default());
            }
        }
    }

    #[test]
    fn test_codegen_length_10() {
        let example_10 = SparseArray::create(
            [0x33333, 0x1234, 0xFFFFF, 0x5678, 0x22222, 0xDEF0, 0x11111, 0x9ABC, 0x44444, 0x55555],
            [700, 100, 1000, 200, 600, 400, 500, 300, 800, 900],
            0x100000,
        );

        let table: SparseArray<10, Field> = SparseArray {
            keys: [
                0x00000000, 0x00001234, 0x00005678, 0x00009abc, 0x0000def0, 0x00011111, 0x00022222,
                0x00033333, 0x00044444, 0x00055555, 0x000fffff, 0x000fffff,
            ],
            values: [
                0x00000000, 0x00000000, 0x000001f4, 0x000002bc, 0x00000384, 0x00000064, 0x00000190,
                0x000000c8, 0x00000258, 0x000003e8, 0x0000012c, 0x00000320, 0x00000000,
            ],
            maximum: 0x000fffff,
        };

        // sample blank space
        for i in 0..(0x100000 / 0x00100) {
            let index = (i * 0x00100) as Field;
            assert(example_10.get(index) == table.get(index));
        }

        // check all keys
        for i in 0..example_10.keys.len() {
            let key = example_10.keys[i];
            assert(example_10.get(key) == table.get(key));
        }

        // check maximum
        assert_eq(table.maximum, example_10.maximum);
    }

    #[test]
    fn test_codegen_length_25() {
        let example_25 = SparseArray::create(
            [
                0xE000, 0x1000, 0x50000, 0x8000, 0x20000, 0xA000, 0x30000, 0x6000, 0x90000, 0xF000,
                0x40000, 0x100, 0xB000, 0x70000, 0x2000, 0xC000, 0x3000, 0x80000, 0x4000, 0xD000,
                0x5000, 0x10000, 0x7000, 0x60000, 0x9000,
            ],
            [
                7777, 222, 33333, 888, 11111, 2222, 22222, 777, 77777, 8888, 44444, 111, 3333,
                55555, 333, 4444, 444, 66666, 555, 5555, 666, 9999, 999, 44444, 1111,
            ],
            0x100000,
        );

        let table: SparseArray<25, Field> = SparseArray {
            keys: [
                0x00000000, 0x00000100, 0x00001000, 0x00002000, 0x00003000, 0x00004000, 0x00005000,
                0x00006000, 0x00007000, 0x00008000, 0x00009000, 0x0000a000, 0x0000b000, 0x0000c000,
                0x0000d000, 0x0000e000, 0x0000f000, 0x00010000, 0x00020000, 0x00030000, 0x00040000,
                0x00050000, 0x00060000, 0x00070000, 0x00080000, 0x00090000, 0x00100000,
            ],
            values: [
                0x00000000, 0x00000000, 0x0000014d, 0x000000de, 0x0000029a, 0x00012fd1, 0x0001046a,
                0x0000ad9c, 0x0000022b, 0x000056ce, 0x00000457, 0x0000115c, 0x000015b3, 0x00001e61,
                0x0000006f, 0x000003e7, 0x00008235, 0x00000d05, 0x00000378, 0x0000ad9c, 0x00002b67,
                0x0000d903, 0x000008ae, 0x000001bc, 0x00000309, 0x0000270f, 0x000022b8, 0x00000000,
            ],
            maximum: 0x000fffff,
        };

        // sample blank space
        for i in 0..(0x100000 / 0x00100) {
            let index = (i * 0x00100) as Field;
            assert(example_25.get(index) == table.get(index));
        }

        // check all keys
        for i in 0..example_25.keys.len() {
            let key = example_25.keys[i];
            assert(example_25.get(key) == table.get(key));
        }

        // check maximum
        assert_eq(table.maximum, example_25.maximum);
    }

    #[test]
    fn test_codegen_length_50() {
        let example_50 = SparseArray::create(
            [
                0x3700, 0x100, 0x2200, 0x4300, 0x1800, 0x3300, 0x900, 0x2800, 0x4400, 0x1400,
                0x2F00, 0xE00, 0x2500, 0x3F00, 0x1B00, 0x3600, 0xC00, 0x2B00, 0x4000, 0x1700,
                0x3200, 0x800, 0x2100, 0x3C00, 0x1300, 0x2D00, 0x400, 0x1900, 0x3800, 0xF00, 0x2600,
                0x200, 0x1500, 0x3400, 0xB00, 0x2A00, 0x4100, 0x1600, 0x3100, 0x700, 0x2000, 0x3900,
                0x1200, 0x2C00, 0x4200, 0x1A00, 0x3500, 0xD00, 0x2700, 0x3000,
            ],
            [
                3700, 100, 2200, 4300, 1800, 3300, 900, 2800, 4400, 1400, 2900, 1300, 2500, 3900,
                1900, 3600, 1200, 2700, 4000, 1700, 3200, 800, 2100, 3800, 1300, 2800, 400, 1900,
                3700, 1500, 2600, 200, 1500, 3400, 1100, 2600, 4100, 1600, 3100, 700, 2000, 3900,
                1200, 2700, 4200, 1800, 3500, 1300, 2700, 3000,
            ],
            0x5000,
        );

        let table: SparseArray<50, Field> = SparseArray {
            keys: [
                0x00000000, 0x00000100, 0x00000200, 0x00000400, 0x00000700, 0x00000800, 0x00000900,
                0x00000b00, 0x00000c00, 0x00000d00, 0x00000e00, 0x00000f00, 0x00001200, 0x00001300,
                0x00001400, 0x00001500, 0x00001600, 0x00001700, 0x00001800, 0x00001900, 0x00001a00,
                0x00001b00, 0x00002000, 0x00002100, 0x00002200, 0x00002500, 0x00002600, 0x00002700,
                0x00002800, 0x00002a00, 0x00002b00, 0x00002c00, 0x00002d00, 0x00002f00, 0x00003000,
                0x00003100, 0x00003200, 0x00003300, 0x00003400, 0x00003500, 0x00003600, 0x00003700,
                0x00003800, 0x00003900, 0x00003c00, 0x00003f00, 0x00004000, 0x00004100, 0x00004200,
                0x00004300, 0x00004400, 0x00005000,
            ],
            values: [
                0x00000000, 0x00000000, 0x000007d0, 0x00000e74, 0x00000ed8, 0x00000a8c, 0x00000a8c,
                0x00001004, 0x00000ce4, 0x0000076c, 0x00000bb8, 0x00000f3c, 0x000005dc, 0x00000578,
                0x00000514, 0x00001068, 0x00000c80, 0x000002bc, 0x00000af0, 0x000005dc, 0x00000708,
                0x000004b0, 0x00000a28, 0x00000708, 0x00000834, 0x00000a8c, 0x000009c4, 0x000000c8,
                0x00000898, 0x00000fa0, 0x00000f3c, 0x00000b54, 0x00000af0, 0x00000064, 0x0000076c,
                0x00000640, 0x00000384, 0x00000e74, 0x00000dac, 0x00000e10, 0x0000044c, 0x000010cc,
                0x00000320, 0x000004b0, 0x00000514, 0x00000a28, 0x00000514, 0x000006a4, 0x00000c1c,
                0x00001130, 0x00000190, 0x00000d48, 0x00000000,
            ],
            maximum: 0x00004fff,
        };

        // sample blank space
        for i in 0..(0x00005000 / 0x0010) {
            let index = (i * 0x0010) as Field;
            assert(example_50.get(index) == table.get(index));
        }

        // check all keys
        for i in 0..example_50.keys.len() {
            let key = example_50.keys[i];
            assert(example_50.get(key) == table.get(key));
        }

        // check maximum
        assert_eq(table.maximum, example_50.maximum);
    }
}
