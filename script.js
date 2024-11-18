// Configuración de Supabase
const supabaseUrl = 'https://vgjfblpelkhhdnpcebjs.supabase.co'; // URL de tu Supabase
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZnamZibHBlbGtoaGRucGNlYmpzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzE3NjU5NDQsImV4cCI6MjA0NzM0MTk0NH0.tjd8SZEEgFnZ2JV3O3RcjZ1X2nQK6MI04sWWsBX-5Pc'; // Clave pública anónima de Supabase
const supabase = supabase.createClient(supabaseUrl, supabaseKey);

let map;
let product = [];

// Inicializar el mapa
function initMap() {
    if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(
            (position) => {
                const userLocation = {
                    lat: position.coords.latitude,
                    lng: position.coords.longitude
                };

                map = new google.maps.Map(document.getElementById("map"), {
                    center: userLocation,
                    zoom: 14
                });

                new google.maps.Marker({
                    position: userLocation,
                    map: map,
                    title: "Tu ubicación"
                });
            },
            () => {
                alert("No se pudo obtener la ubicación.");
            }
        );
    } else {
        alert("Geolocalización no es soportada por este navegador.");
    }
}

// Función para agregar un producto
async function addProduct() {
    const productName = document.getElementById("productName").value;
    const productPrice = parseFloat(document.getElementById("productPrice").value);
    const storeName = document.getElementById("storeLocation").value;
    const productImage = document.getElementById("productImage").files[0];

    if (productName && !isNaN(productPrice) && storeName && productImage) {
        // Convertir la imagen a un URL base64 para almacenamiento o usa el almacenamiento de Supabase
        const reader = new FileReader();
        reader.onloadend = async function () {
            const productData = {
                name: productName,
                price: productPrice,
                store: storeName,
                image: reader.result, // Guarda la imagen en formato base64
                location: {
                    lat: map.getCenter().lat(),
                    lng: map.getCenter().lng()
                },
                created_at: new Date().toISOString()
            };

            // Guardar en Supabase en la tabla 'product'
            const { data, error } = await supabase
                .from('product')  // Tabla 'product'
                .insert([productData]);

            if (error) {
                console.error('Error al agregar el producto:', error);
                alert('Hubo un problema al agregar el producto.');
            } else {
                alert('Producto agregado exitosamente.');

                // Limpiar los campos del formulario después de agregar el producto
                document.getElementById("productName").value = '';
                document.getElementById("productPrice").value = '';
                document.getElementById("storeLocation").value = '';
                document.getElementById("productImage").value = '';

                products.push(data[0]); // Agregar el producto a la lista en memoria
            }
        };

        reader.readAsDataURL(productImage);  // Convierte la imagen a base64
    } else {
        alert("Por favor, completa todos los campos.");
    }
}

// Función para buscar el mejor precio
function searchBestPrice() {
    const searchProductName = document.getElementById("searchProductName").value.toLowerCase();

    let bestPrice = Infinity;
    let bestProduct = null;

    // Filtrar productos en memoria (puedes mejorar esto haciendo una consulta a la base de datos)
    products.forEach(product => {
        if (product.name.toLowerCase() === searchProductName && product.price < bestPrice) {
            bestPrice = product.price;
            bestProduct = product;
        }
    });

    if (bestProduct) {
        document.getElementById("bestStore").textContent = bestProduct.store;
        document.getElementById("bestPrice").textContent = bestPrice.toFixed(2);
        document.getElementById("bestLocation").textContent = `${bestProduct.location.lat}, ${bestProduct.location.lng}`;
        document.getElementById("recommendationBox").style.display = "block";
    } else {
        alert("Producto no encontrado.");
    }
}

// Función para cargar productos desde Supabase (opcional, si deseas cargar los productos al cargar la página)
async function loadProducts() {
    const { data, error } = await supabase
        .from('product') // Nombre correcto de la tabla
        .select('*');

    if (error) {
        console.error('Error al cargar productos:', error);
    } else {
        products = data;
    }
}

// Cargar los productos al iniciar la página
loadProducts();
